use CRoaring;

# === Term: leaf data for a single tag or numeric condition ===

class Roaring::Tags::Query::Term {
	has Str:D $.raw is required;
	has Bool:D $.negated = False;
	has Str $.tag;
	has Str $.field;
	has Int $.gt;
	has Int $.gte;
	has Int $.lt;
	has Int $.lte;

	method is-numeric(--> Bool:D) { $!field.defined }
	method is-tag(--> Bool:D) { $!tag.defined }

	method description(--> Str:D) {
		my Str:D $prefix = $!negated ?? '-' !! '';
		if self.is-numeric {
			my @parts;
			@parts.push(">{$!gt}") if $!gt.defined;
			@parts.push(">={$!gte}") if $!gte.defined;
			@parts.push("<{$!lt}") if $!lt.defined;
			@parts.push("<={$!lte}") if $!lte.defined;
			"$prefix$!field:{@parts.join(',')}";
		} else {
			"$prefix$!tag";
		}
	}
}

# === AST Nodes ===
#
# Ownership rule: every execute() returns a bitmap OWNED by the caller.
# TermNode clones tag bitmaps so the caller can safely dispose.
# Compound nodes dispose all child results after combining.

role Roaring::Tags::Query::Node {
	method execute($tags --> CRoaring:D) { ... }
	method describe($tags = Nil, Int:D :$indent = 0 --> Str:D) { ... }
	method collect-terms(--> List) { ... }
}

class Roaring::Tags::Query::TermNode does Roaring::Tags::Query::Node {
	has Roaring::Tags::Query::Term $.term is required;

	method execute($tags --> CRoaring:D) {
		if $!term.is-numeric {
			$tags.range($!term.field, :gt($!term.gt), :gte($!term.gte),
				:lt($!term.lt), :lte($!term.lte));
		} else {
			$tags.query($!term.tag);
		}
	}

	method describe($tags = Nil, Int:D :$indent = 0 --> Str:D) {
		my Str:D $pad = ' ' x $indent;
		if $tags.defined {
			# Both query() and range() return owned bitmaps — dispose after use
			my CRoaring:D $bm = self.execute($tags);
			my Int $card = $bm.cardinality;
			$bm.dispose;
			"{$pad}{$!term.description} (cardinality: $card)";
		} else {
			"{$pad}{$!term.description}";
		}
	}

	method collect-terms(--> List) { ($!term,) }
}

class Roaring::Tags::Query::AndNode does Roaring::Tags::Query::Node {
	has Roaring::Tags::Query::Node @.children is required;

	method execute($tags --> CRoaring:D) {
		my @positive;
		my @negative;
		for @!children -> Roaring::Tags::Query::Node $child {
			if $child ~~ Roaring::Tags::Query::TermNode && $child.term.negated {
				@negative.push($child);
			} else {
				@positive.push($child);
			}
		}

		# Track all owned bitmaps for cleanup on exception
		my CRoaring @owned;

		{
			my CRoaring $result;

			if @positive.elems > 0 {
				# Resolve positive children — each returns an owned bitmap
				my @resolved;
				for @positive -> Roaring::Tags::Query::Node $child {
					my CRoaring:D $bm = $child.execute($tags);
					@owned.push($bm);
					@resolved.push({ node => $child, bitmap => $bm, cardinality => $bm.cardinality });
				}
				@resolved = @resolved.sort({ $^a<cardinality> <=> $^b<cardinality> });

				# Start with the smallest — we own it, use it directly
				$result = @resolved[0]<bitmap>;

				# Intersect remaining, dispose both operands after each step
				for @resolved[1..*] -> %entry {
					my CRoaring:D $new = $result.and(%entry<bitmap>);
					$result.dispose;
					%entry<bitmap>.dispose;
					@owned = @owned.grep({ $_ !=== $result && $_ !=== %entry<bitmap> });
					@owned.push($new);
					$result = $new;
				}
			} else {
				# All-negative query: start from universe
				$result = $tags.universe.clone;
				@owned.push($result);
			}

			# ANDNOT negatives, dispose both operands after each step
			for @negative -> Roaring::Tags::Query::Node $child {
				my CRoaring:D $neg-bm = $child.execute($tags);
				@owned.push($neg-bm);
				my CRoaring:D $new = $result.andnot($neg-bm);
				$result.dispose;
				$neg-bm.dispose;
				@owned = @owned.grep({ $_ !=== $result && $_ !=== $neg-bm });
				@owned.push($new);
				$result = $new;
			}

			# Success: clear owned list so CATCH doesn't dispose the result
			@owned = ();
			return $result;

			CATCH {
				default {
					for @owned -> CRoaring $bm {
						$bm.dispose;
					}
					.rethrow;
				}
			}
		}
	}

	method describe($tags = Nil, Int:D :$indent = 0 --> Str:D) {
		my Str:D $pad = ' ' x $indent;
		my @lines = "{$pad}AND";
		for @!children -> Roaring::Tags::Query::Node $child {
			@lines.push($child.describe($tags, :indent($indent + 2)));
		}
		@lines.join("\n");
	}

	method collect-terms(--> List) {
		@!children.map(*.collect-terms).flat.list;
	}
}

class Roaring::Tags::Query::OrNode does Roaring::Tags::Query::Node {
	has Roaring::Tags::Query::Node @.children is required;

	method execute($tags --> CRoaring:D) {
		my CRoaring @owned;

		{
			my CRoaring:D $result = @!children[0].execute($tags);
			@owned.push($result);

			for @!children[1..*] -> Roaring::Tags::Query::Node $child {
				my CRoaring:D $child-bm = $child.execute($tags);
				@owned.push($child-bm);
				my CRoaring:D $new = $result.or($child-bm);
				$result.dispose;
				$child-bm.dispose;
				@owned = @owned.grep({ $_ !=== $result && $_ !=== $child-bm });
				@owned.push($new);
				$result = $new;
			}

			@owned = ();
			return $result;

			CATCH {
				default {
					for @owned -> CRoaring $bm { $bm.dispose }
					.rethrow;
				}
			}
		}
	}

	method describe($tags = Nil, Int:D :$indent = 0 --> Str:D) {
		my Str:D $pad = ' ' x $indent;
		my @lines = "{$pad}OR";
		for @!children -> Roaring::Tags::Query::Node $child {
			@lines.push($child.describe($tags, :indent($indent + 2)));
		}
		@lines.join("\n");
	}

	method collect-terms(--> List) {
		@!children.map(*.collect-terms).flat.list;
	}
}

# === Grammar ===
#
# Precedence: parens > AND (comma) > OR
# a OR b, c  →  a OR (b AND c)
# a, b OR c  →  (a AND b) OR c   -- NO: actually a, (b OR c)
# Wait — standard boolean: AND binds tighter than OR.
# So: a OR b, c  means  a OR (b AND c)
# And: a, b OR c  means  (a AND b) OR c?  No — AND is tighter, so
# comma groups first: the only way to get OR is the OR keyword.
#
# Grammar:  query = or-expr
#           or-expr = and-expr ('OR' and-expr)*
#           and-expr = term (',' term)*
#           term = group | atom
#           group = '(' or-expr ')'

grammar Roaring::Tags::Query::Grammar {
	rule TOP        { ^ <or-expr> $ }
	rule or-expr    { <and-expr>+ % 'OR' }
	rule and-expr   { <term>+ % ',' }
	rule term       { <group> || <atom> }
	rule group      { '(' <or-expr> ')' }
	token atom      { <negation>? [ <numeric> || <tag> ] }
	token negation  { '-' }
	token numeric   { <field> ':' [ <range> || <comparison> ] }
	token range     { $<min>=[\d+] '..' $<max>=[\d+] }
	token comparison { $<op>=['>=' || '>' || '<=' || '<'] $<val>=[\d+] }
	token field     { <-[,:()>\s]>+ }
	token tag       { <-[,()>\s]>+ }
}

# === Actions ===

class Roaring::Tags::Query::Actions {
	method TOP($/) {
		make $<or-expr>.made;
	}

	method or-expr($/) {
		my @children = $<and-expr>.map(*.made);
		if @children.elems == 1 {
			make @children[0];
		} else {
			make Roaring::Tags::Query::OrNode.new(:@children);
		}
	}

	method and-expr($/) {
		my @children = $<term>.map(*.made);
		if @children.elems == 1 {
			make @children[0];
		} else {
			make Roaring::Tags::Query::AndNode.new(:@children);
		}
	}

	method term($/) {
		make $<group>.defined ?? $<group>.made !! $<atom>.made;
	}

	method group($/) {
		make $<or-expr>.made;
	}

	method atom($/) {
		my Bool:D $negated = $<negation>.defined;
		my Roaring::Tags::Query::Term $term;

		if $<numeric>.defined {
			my Str:D $field = ~$<numeric><field>;
			my Int $gt;
			my Int $gte;
			my Int $lt;
			my Int $lte;

			if $<numeric><range>.defined {
				$gte = $<numeric><range><min>.Int;
				$lte = $<numeric><range><max>.Int;
			} elsif $<numeric><comparison>.defined {
				my Str:D $op = ~$<numeric><comparison><op>;
				my Int:D $val = $<numeric><comparison><val>.Int;
				given $op {
					when '>='  { $gte = $val }
					when '>'   { $gt = $val }
					when '<='  { $lte = $val }
					when '<'   { $lt = $val }
				}
			}

			$term = Roaring::Tags::Query::Term.new(
				:raw(~$/), :$negated, :$field, :$gt, :$gte, :$lt, :$lte);
		} else {
			$term = Roaring::Tags::Query::Term.new(
				:raw(~$/), :$negated, :tag(~$<tag>));
		}

		make Roaring::Tags::Query::TermNode.new(:$term);
	}
}

# === Query class ===

class Roaring::Tags::Query {
	has $.tags is required;
	has Str:D $.query-string is required;
	has Roaring::Tags::Query::Node $!root;

	submethod TWEAK() {
		my $match = Roaring::Tags::Query::Grammar.parse(
			$!query-string,
			:actions(Roaring::Tags::Query::Actions.new)
		);
		die "Roaring::Tags::Query: failed to parse query: $!query-string"
			unless $match.defined;
		$!root = $match.made;

		# Ensure root is always an AndNode so negation handling is uniform.
		# A bare TermNode (e.g., "a" or "-a") gets wrapped.
		if $!root ~~ Roaring::Tags::Query::TermNode {
			$!root = Roaring::Tags::Query::AndNode.new(:children([$!root,]));
		}
	}

	method execute(--> CRoaring:D) {
		$!root.execute($!tags);
	}

	method explain(--> Str:D) {
		my @lines;
		@lines.push("Query: $!query-string");
		@lines.push("");
		@lines.push("Execution plan:");
		@lines.push($!root.describe($!tags, :indent(2)));
		@lines.join("\n");
	}

	method terms(--> List) {
		$!root.collect-terms;
	}

	method tree(--> Roaring::Tags::Query::Node) {
		$!root;
	}
}
