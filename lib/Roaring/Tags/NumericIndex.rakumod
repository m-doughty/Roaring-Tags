use CRoaring;
use CRoaring::FFI;
use NativeCall;

unit class Roaring::Tags::NumericIndex;

# Parallel native buffers: values[i] and doc-ids[i] form a pair
# Sorted by (value, doc-id) ascending. Packed little-endian uint32.
has Buf $!values .= new;
has Buf $!doc-ids .= new;
has Int:D $!count = 0;

# Fast lookup: doc-id → value
has Int %!doc-values;

method !val-at(Int:D $i --> Int:D) {
	$!values.read-uint32($i * 4, LittleEndian);
}

method !id-at(Int:D $i --> Int:D) {
	$!doc-ids.read-uint32($i * 4, LittleEndian);
}

method insert(Int:D $doc-id, Int:D $value --> Nil) {
	# Use insert-many for single inserts — same correctness path
	self.insert-many([[$doc-id, $value],]);
}

method insert-many(@pairs --> Nil) {
	my Int:D $n = @pairs.elems;
	return unless $n > 0;

	# Pack incoming pairs into native buffers AND update hash in one pass
	my Buf $in-ids .= allocate($n * 4);
	my Buf $in-vals .= allocate($n * 4);
	my Int:D $write-idx = 0;
	for @pairs -> $pair {
		my Int:D $doc-id = $pair[0].Int;
		my Int:D $value = $pair[1].Int;
		$in-ids.write-uint32($write-idx * 4, $doc-id, LittleEndian);
		$in-vals.write-uint32($write-idx * 4, $value, LittleEndian);
		%!doc-values{$doc-id} = $value;
		$write-idx++;
	}

	# Dedupe incoming: keep last value per doc-id (in C)
	my Int:D $deduped-count = croaring_dedupe_pairs(
		nativecast(Pointer[uint32], $in-ids),
		nativecast(Pointer[uint32], $in-vals),
		$n,
	).Int;

	# Sort deduped pairs by (value, doc_id) in C
	my Buf $sorted-vals .= allocate($deduped-count * 4);
	my Buf $sorted-ids .= allocate($deduped-count * 4);
	croaring_build_index(
		nativecast(Pointer[uint32], $in-ids),
		nativecast(Pointer[uint32], $in-vals),
		$deduped-count,
		nativecast(Pointer[uint32], $sorted-vals),
		nativecast(Pointer[uint32], $sorted-ids),
	);

	if $!count == 0 {
		# Fast path: empty index, just assign
		$!values = $sorted-vals;
		$!doc-ids = $sorted-ids;
		$!count = $deduped-count;
	} else {
		# Remove overlapping doc-ids from existing index before merge.
		# The C remove function uses bitmap lookup, so order doesn't matter.
		my Int:D $cleaned-count = croaring_remove_docs_from_index(
			nativecast(Pointer[uint32], $!values),
			nativecast(Pointer[uint32], $!doc-ids),
			$!count,
			nativecast(Pointer[uint32], $in-ids),
			$deduped-count,
		).Int;

		# Merge cleaned existing + new sorted (in C)
		my Int:D $total = $cleaned-count + $deduped-count;
		my Buf $merged-vals .= allocate($total * 4);
		my Buf $merged-ids .= allocate($total * 4);
		my Int:D $written = croaring_merge_sorted_pairs(
			nativecast(Pointer[uint32], $!values),
			nativecast(Pointer[uint32], $!doc-ids),
			$cleaned-count,
			nativecast(Pointer[uint32], $sorted-vals),
			nativecast(Pointer[uint32], $sorted-ids),
			$deduped-count,
			nativecast(Pointer[uint32], $merged-vals),
			nativecast(Pointer[uint32], $merged-ids),
		).Int;

		$!values = $merged-vals;
		$!doc-ids = $merged-ids;
		$!count = $written;
	}
}

method remove(Int:D $doc-id --> Nil) {
	return unless %!doc-values{$doc-id}:exists;
	%!doc-values{$doc-id}:delete;

	# Build single-element sorted remove set
	my Buf $remove-buf .= allocate(4);
	$remove-buf.write-uint32(0, $doc-id, LittleEndian);

	my Int:D $new-count = croaring_remove_docs_from_index(
		nativecast(Pointer[uint32], $!values),
		nativecast(Pointer[uint32], $!doc-ids),
		$!count,
		nativecast(Pointer[uint32], $remove-buf),
		1,
	).Int;

	if $new-count < $!count {
		# Shrink buffers
		if $new-count == 0 {
			$!values = Buf.new;
			$!doc-ids = Buf.new;
		} else {
			$!values = $!values.subbuf(0, $new-count * 4);
			$!doc-ids = $!doc-ids.subbuf(0, $new-count * 4);
		}
		$!count = $new-count;
	}
}

method get(Int:D $doc-id --> Int) {
	%!doc-values{$doc-id} // Int;
}

method range(Int :$gt, Int :$gte, Int :$lt, Int :$lte --> CRoaring:D) {
	my Int $lower;
	if $gte.defined {
		$lower = $gte;
	} elsif $gt.defined {
		$lower = $gt + 1;
	}

	my Int $upper;
	if $lte.defined {
		$upper = $lte;
	} elsif $lt.defined {
		$upper = $lt - 1;
	}

	my Int:D $start = $lower.defined ?? self!lower-bound($lower) !! 0;
	my Int:D $end = $upper.defined ?? self!upper-bound($upper) !! $!count;

	my Int:D $count = $end - $start;
	return CRoaring.new if $count <= 0;

	# Pass doc-ids sub-buffer directly to C
	my Buf $id-slice = $!doc-ids.subbuf($start * 4, $count * 4);
	my CRoaring $bm .= new;
	roaring_bitmap_add_many($bm.handle, $count, nativecast(CArray[uint32], $id-slice));
	$bm;
}

method elems(--> Int:D) {
	%!doc-values.elems;
}

method entries(--> List) {
	(^$!count).map({ [self!val-at($_), self!id-at($_)] }).list;
}

method doc-values(--> Hash) {
	%!doc-values.Hash;
}

method from-entries(@entries --> Roaring::Tags::NumericIndex:D) {
	my Roaring::Tags::NumericIndex $idx .= new;
	# entries are [value, doc-id], convert to [doc-id, value] for insert-many
	my @pairs = @entries.map(-> @e { [@e[1], @e[0]] });
	$idx.insert-many(@pairs);
	$idx;
}

method !lower-bound(Int:D $target --> Int:D) {
	my Int:D $lo = 0;
	my Int:D $hi = $!count;
	while $lo < $hi {
		my Int:D $mid = ($lo + $hi) div 2;
		if self!val-at($mid) < $target {
			$lo = $mid + 1;
		} else {
			$hi = $mid;
		}
	}
	$lo;
}

method !upper-bound(Int:D $target --> Int:D) {
	my Int:D $lo = 0;
	my Int:D $hi = $!count;
	while $lo < $hi {
		my Int:D $mid = ($lo + $hi) div 2;
		if self!val-at($mid) <= $target {
			$lo = $mid + 1;
		} else {
			$hi = $mid;
		}
	}
	$lo;
}
