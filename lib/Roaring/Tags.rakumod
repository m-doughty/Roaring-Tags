use CRoaring;
use Roaring::Tags::NumericIndex;
use Roaring::Tags::Storage;
use Roaring::Tags::Query;

unit class Roaring::Tags;

has CRoaring %!bitmaps;
has Roaring::Tags::NumericIndex %!numeric;
has CRoaring $!universe .= new;

# --- Boolean / Categorical tagging ---

multi method tag(Str:D $key, Int:D $doc-id --> Nil) {
	%!bitmaps{$key} //= CRoaring.new;
	%!bitmaps{$key}.add($doc-id);
	$!universe.add($doc-id);
}

multi method tag(Str:D $field, Str:D $value, Int:D $doc-id --> Nil) {
	self.tag("$field:$value", $doc-id);
}

method tag-many(Str:D $key, @doc-ids --> Nil) {
	%!bitmaps{$key} //= CRoaring.new;
	%!bitmaps{$key}.add-many(@doc-ids);
	$!universe.add-many(@doc-ids);
}

multi method untag(Str:D $key, Int:D $doc-id --> Nil) {
	%!bitmaps{$key}.remove($doc-id) if %!bitmaps{$key}:exists;
	self!maybe-remove-from-universe($doc-id);
}

multi method untag(Str:D $field, Str:D $value, Int:D $doc-id --> Nil) {
	self.untag("$field:$value", $doc-id);
}

method untag-many(Str:D $key, @doc-ids --> Nil) {
	return unless %!bitmaps{$key}:exists;
	for @doc-ids -> Int:D $id {
		%!bitmaps{$key}.remove($id);
		self!maybe-remove-from-universe($id);
	}
}

method has-tag(Str:D $key, Int:D $doc-id --> Bool:D) {
	return False unless %!bitmaps{$key}:exists;
	%!bitmaps{$key}.contains($doc-id);
}

# --- Numeric properties ---

method set-value(Str:D $field, Int:D $doc-id, Int:D $value --> Nil) {
	%!numeric{$field} //= Roaring::Tags::NumericIndex.new;
	%!numeric{$field}.insert($doc-id, $value);
	$!universe.add($doc-id);
}

method set-values(Str:D $field, @pairs --> Nil) {
	%!numeric{$field} //= Roaring::Tags::NumericIndex.new;
	%!numeric{$field}.insert-many(@pairs);
	# Add all doc-ids to universe
	$!universe.add-many(@pairs.map({ $_[0].Int }));
}

method get-value(Str:D $field, Int:D $doc-id --> Int) {
	return Int unless %!numeric{$field}:exists;
	%!numeric{$field}.get($doc-id);
}

method remove-value(Str:D $field, Int:D $doc-id --> Nil) {
	%!numeric{$field}.remove($doc-id) if %!numeric{$field}:exists;
	self!maybe-remove-from-universe($doc-id);
}

# --- Query ---

multi method query(Str:D $key --> CRoaring:D) {
	my CRoaring $live = %!bitmaps{$key};
	$live.defined ?? $live.clone !! CRoaring.new;
}

multi method query(Str:D $field, Str:D $value --> CRoaring:D) {
	self.query("$field:$value");
}

method range(Str:D $field, Int :$gt, Int :$gte, Int :$lt, Int :$lte --> CRoaring:D) {
	return CRoaring.new unless %!numeric{$field}:exists;
	%!numeric{$field}.range(:$gt, :$gte, :$lt, :$lte);
}

# --- Document operations ---

method remove-doc(Int:D $doc-id --> Nil) {
	for %!bitmaps.values -> CRoaring $bm {
		$bm.remove($doc-id);
	}
	for %!numeric.values -> Roaring::Tags::NumericIndex $idx {
		$idx.remove($doc-id);
	}
	$!universe.remove($doc-id);
}

method doc-tags(Int:D $doc-id --> List) {
	%!bitmaps.keys.grep(-> Str:D $k { %!bitmaps{$k}.contains($doc-id) }).sort.list;
}

method doc-values(Int:D $doc-id --> Hash) {
	my %result;
	for %!numeric.kv -> Str:D $field, Roaring::Tags::NumericIndex $idx {
		my Int $val = $idx.get($doc-id);
		%result{$field} = $val if $val.defined;
	}
	%result;
}

# --- Introspection ---

method tags(--> List) {
	%!bitmaps.keys.sort.list;
}

method boolean-tags(--> List) {
	%!bitmaps.keys.grep({ !.contains(':') }).sort.list;
}

method fields(--> List) {
	my SetHash $fields .= new;
	for %!bitmaps.keys.grep({ .contains(':') }) -> Str:D $key {
		$fields.set($key.split(':', 2)[0]);
	}
	$fields.set($_) for %!numeric.keys;
	$fields.keys.sort.list;
}

method field-values(Str:D $field --> List) {
	%!bitmaps.keys
		.grep({ .starts-with("$field:") })
		.map({ .split(':', 2)[1] })
		.sort.list;
}

method numeric-fields(--> List) {
	%!numeric.keys.sort.list;
}

method count(Str:D $key --> Int:D) {
	return 0 unless %!bitmaps{$key}:exists;
	%!bitmaps{$key}.cardinality;
}

# --- Search ---

method search(Str:D $query-string --> CRoaring:D) {
	Roaring::Tags::Query.new(:tags(self), :$query-string).execute;
}

# --- Persistence ---

method save(IO::Path:D $dir --> Nil) {
	Roaring::Tags::Storage.save(self, $dir);
}

method load(IO::Path:D $dir --> Roaring::Tags:D) {
	my (%bitmaps, %numeric, $universe) := Roaring::Tags::Storage.load($dir);
	my Roaring::Tags $tags .= new;
	$tags.set-bitmap-store(%bitmaps);
	$tags.set-numeric-store(%numeric);
	$tags.set-universe($universe);
	$tags;
}

# --- Internal helpers ---

method !maybe-remove-from-universe(Int:D $doc-id --> Nil) {
	return unless $!universe.contains($doc-id);
	# Check if doc still exists in any bitmap
	for %!bitmaps.values -> CRoaring $bm {
		return if $bm.contains($doc-id);
	}
	# Check if doc still exists in any numeric index
	for %!numeric.values -> Roaring::Tags::NumericIndex $idx {
		return if $idx.get($doc-id).defined;
	}
	# Doc is nowhere — remove from universe
	$!universe.remove($doc-id);
}

# --- Internal accessors (for Storage) ---

method bitmap-store(--> Hash) { %!bitmaps }
method numeric-store(--> Hash) { %!numeric }
method universe(--> CRoaring) { $!universe }

method set-bitmap-store(%bitmaps --> Nil) {
	%!bitmaps = %bitmaps;
}

method set-numeric-store(%numeric --> Nil) {
	%!numeric = %numeric;
}

method set-universe(CRoaring:D $universe --> Nil) {
	$!universe = $universe;
}
