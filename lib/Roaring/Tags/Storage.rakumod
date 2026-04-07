use JSON::Fast;
use CRoaring;
use Roaring::Tags::NumericIndex;

unit class Roaring::Tags::Storage;

method save($tags, IO::Path:D $dir --> Nil) {
	# Create directory structure
	$dir.mkdir unless $dir.d;
	$dir.add('bitmaps').mkdir unless $dir.add('bitmaps').d;
	$dir.add('numeric').mkdir unless $dir.add('numeric').d;

	my %files;
	my @bitmap-keys;
	my @numeric-fields;

	# Save bitmaps
	for $tags.bitmap-store.kv -> Str:D $key, CRoaring $bm {
		@bitmap-keys.push($key);
		my Str:D $filename = self!safe-filename($key);
		%files{$key} = $filename;
		$dir.add("bitmaps/$filename.crb").spurt($bm.serialize, :bin);
	}

	# Save numeric indices
	for $tags.numeric-store.kv -> Str:D $field, Roaring::Tags::NumericIndex $idx {
		@numeric-fields.push($field);
		my Str:D $filename = self!safe-filename($field);
		%files{$field} = $filename;
		my @entries = $idx.entries;
		# Pack as JSON for simplicity in v1
		my @packed = @entries.map({ [$_[0], $_[1]] });
		$dir.add("numeric/$filename.json").spurt(to-json(@packed, :!pretty));
	}

	# Save universe bitmap
	$dir.add("bitmaps/__universe__.crb").spurt($tags.universe.serialize, :bin);

	# Write metadata
	my %meta = %(
		version => 2,
		bitmaps => @bitmap-keys.sort.list,
		numeric => @numeric-fields.sort.list,
		files   => %files,
	);
	$dir.add('meta.json').spurt(to-json(%meta, :sorted-keys));
}

method load(IO::Path:D $dir --> Any) {
	die "Roaring::Tags::Storage: directory not found: $dir" unless $dir.d;
	die "Roaring::Tags::Storage: meta.json not found in $dir" unless $dir.add('meta.json').e;

	my %meta = from-json($dir.add('meta.json').slurp);

	# We need to defer the actual Roaring::Tags import to avoid circular dependency
	# So we return the raw data and let the caller construct
	my %bitmaps;
	for @(%meta<bitmaps>) -> Str $key {
		my Str:D $filename = %meta<files>{$key};
		my Buf $data = $dir.add("bitmaps/$filename.crb").slurp(:bin);
		%bitmaps{$key} = CRoaring.deserialize($data);
	}

	my %numeric;
	for @(%meta<numeric>) -> Str $field {
		my Str:D $filename = %meta<files>{$field};
		my @packed = from-json($dir.add("numeric/$filename.json").slurp);
		%numeric{$field} = Roaring::Tags::NumericIndex.from-entries(@packed);
	}

	# Load universe
	my CRoaring $universe;
	my IO::Path $universe-path = $dir.add("bitmaps/__universe__.crb");
	if $universe-path.e {
		$universe = CRoaring.deserialize($universe-path.slurp(:bin));
	} else {
		# v1 format without universe — rebuild from all bitmaps
		$universe = CRoaring.new;
		for %bitmaps.values -> CRoaring $bm {
			my CRoaring $merged = $universe.or($bm);
			$universe.dispose;
			$universe = $merged;
		}
	}

	(%bitmaps, %numeric, $universe);
}

method !safe-filename(Str:D $key --> Str:D) {
	$key.subst(/<-[a..zA..Z0..9_-]>/, '_', :g);
}
