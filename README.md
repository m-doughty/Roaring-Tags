[![Actions Status](https://github.com/m-doughty/Roaring-Tags/actions/workflows/test.yml/badge.svg)](https://github.com/m-doughty/Roaring-Tags/actions)

NAME
====

Roaring::Tags - High-level tag system built on CRoaring bitmaps

SYNOPSIS
========

```raku
use Roaring::Tags;

my $tags = Roaring::Tags.new;

# Boolean tags
$tags.tag('nsfw', 42);
$tags.tag-many('landscape', [1, 2, 3, 4, 5]);
$tags.untag('nsfw', 42);
$tags.has-tag('landscape', 3);     # True

# Categorical tags (field:value)
$tags.tag('genre:fantasy', 42);
$tags.tag('genre', 'romance', 42);   # Two-arg form

# Numeric properties with range queries
$tags.set-value('score', 42, 150);
$tags.set-values('score', ([1, 100], [2, 200]));

# Query — returns owned CRoaring bitmaps
my $results = $tags.query('landscape');
my $fantasy = $tags.query('genre:fantasy');
my $high    = $tags.range('score', :gt(100));

# Compose with CRoaring set operations
my $filtered = $tags.query('landscape')
    .and($tags.range('score', :gte(50)))
    .andnot($tags.query('violent'));

# Search with booru-style query syntax
my $results = $tags.search('landscape, hdr, score:>100, -violent');
my $complex = $tags.search('(landscape, hdr) OR (portrait, bokeh), score:>50');
my $negonly = $tags.search('-nsfw, -violent');  # Uses universe bitmap

# Pagination (newest first)
my @page1 = $results.slice-reverse(0, 20);
my @page2 = $results.slice-reverse(20, 20);

# Introspection
$tags.tags;                        # All tag keys
$tags.boolean-tags;                # Keys without ':'
$tags.fields;                      # Categorical + numeric field names
$tags.field-values('genre');       # ('fantasy', 'romance')
$tags.numeric-fields;              # ('score',)
$tags.count('landscape');          # Cardinality
$tags.doc-tags(42);                # Tags for a document
$tags.doc-values(42);              # Numeric values for a document

# Document removal
$tags.remove-doc(42);              # Removes from all tags, indices, and universe

# Persistence
$tags.save('my-tags'.IO);
my $loaded = Roaring::Tags.load('my-tags'.IO);
```

DESCRIPTION
===========

Roaring::Tags provides a high-level tag system for millions of documents with sub-millisecond set operations. Built on CRoaring compressed bitmaps.

Tag types
---------

  * **Boolean** — `nsfw`, `landscape` — document either has it or doesn't

  * **Categorical** — `genre:fantasy`, `rating:safe` — field:value pairs, multiple values per field

  * **Numeric** — `score`, `token_count` — integer values with range queries

Query syntax
------------

The `search` method accepts booru-style query strings:

    landscape                   # Boolean tag (AND)
    -violent                    # Negation (ANDNOT)
    genre:fantasy               # Categorical tag
    score:>100                  # Numeric: greater than
    score:>=100                 # Numeric: greater than or equal
    score:<50                   # Numeric: less than
    score:<=50                  # Numeric: less than or equal
    score:100..500              # Numeric: inclusive range
    (a, b) OR (c, d)           # OR groups with parentheses
    a OR b                      # Bare OR
    a OR b, c                   # AND binds tighter: a OR (b AND c)
    (a OR b), c                 # Parens override: (a OR b) AND c

Terms are comma-separated (AND). OR binds tighter than comma. Negative-only queries (`-nsfw, -violent`) use the universe bitmap to return everything except the excluded tags.

The execution planner sorts positive terms by ascending cardinality (smallest bitmap first) to minimize intermediate set sizes.

Universe bitmap
---------------

Every document that is tagged or given a numeric value is automatically tracked in a universe bitmap. This enables negative-only queries and is persisted alongside the tag data.

Persistence
-----------

`save` writes a directory with:

  * `meta.json` — tag keys, numeric fields, filename mappings

  * `bitmaps/*.crb` — CRoaring serialized bitmaps

  * `numeric/*.json` — sorted index data

  * `bitmaps/__universe__.crb` — universe bitmap

`load` restores the full state. Compatible with v1 format (rebuilds universe from bitmaps).

Query explain
-------------

```raku
my $q = Roaring::Tags::Query.new(:tags($db), :query-string('(a, b) OR c, -d'));
say $q.explain;
# Query: (a, b) OR c, -d
#
# Execution plan:
#   AND
#     OR
#       AND
#         a (cardinality: 500)
#         b (cardinality: 200)
#       c (cardinality: 1000)
#     -d (cardinality: 50)
```

AUTHOR
======

Matt Doughty <matt@apogee.guru>

COPYRIGHT AND LICENSE
=====================

Copyright 2026 Matt Doughty

This library is free software; you can redistribute it and/or modify it under the Artistic License 2.0.

