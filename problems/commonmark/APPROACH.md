# commonmark — implementation approach

SPEC.md defines what the output must be. This note fixes how the program
computes it. Below, N is the input size in bytes, L the number of lines, D the
block nesting depth (at most 300) and C the length of one paragraph's or
heading's content.

## Overall approach

A single-pass, cmark-style converter with three stages over one in-memory
copy of the input. (1) The block parser walks the input line by line and
maintains the chain of open blocks, appending each line's remaining text to
the open leaf block's content buffer. (2) After the block tree is complete,
each paragraph and heading's content is parsed once, left to right, into
inline nodes with the delimiter stack, bracket stack and process-emphasis
algorithm exactly as SPEC.md describes. (3) An iterative enter/exit walk of
the tree appends HTML to one growable output buffer, which is written to
stdout in one call. Blocks and inlines form one logical tree (they may be
stored in separate arenas) whose children are doubly linked sibling lists
with parent links, so all node surgery is O(1) per node moved.

## Required choices

1. **Input and lines.** Read all of stdin into one byte buffer. Process
   lines as (start, end) views into it; do not split the input into a list
   of separately allocated line strings. Work on bytes, not decoded
   characters: every rule in SPEC.md is ASCII-driven and non-ASCII bytes
   are copied through. This keeps phase 1 at O(N) memory traffic.
2. **Block phase.** For each line, walk the open-block chain from the
   document (step 1), try block starts (step 2), then add text (step 3),
   tracking `offset`, `column` and the partially consumed tab as integers
   on the current line. All scanners (ATX, fences, setext, thematic break,
   list markers) examine the current line in place from a position:
   hand-written byte loops, or anchored, non-backtracking patterns
   matched at a position where that is the idiomatic fast path; never by
   extracting substrings first. Cost O(N + L·D).
3. **Leaf content.** Each paragraph, heading and code block owns one
   growable byte buffer; a line is appended with a single bulk copy
   (plus the spaces of a partially consumed tab). The buffer is finalised
   once when the block closes (trailing-blank removal, info-string
   extraction). Total O(N).
4. **Node storage.** Nodes are compact records allocated in bulk: a
   growable array (arena) of records linked by integer indices, or a pool
   that allocates records in large chunks (in a language without value
   records, the smallest fixed-layout object it offers). Inline nodes carry only what
   inlines need (kind, links, a text span or small string, destination and
   title for links/images); block-only fields (list data, fence data,
   content buffer) are not carried by every inline node. A text node's
   literal is a (start, length) span into its block's content wherever the
   text is a verbatim substring, with a separate small buffer only for
   decoded text (entities, autolink text, normalised code spans,
   destinations and titles). The inline tree has on the order of one node
   per token of a 1 MB input, so per-node allocation size and count
   dominate the run time of phases 2 and 3. Runtime memory-management
   settings stay at their defaults; the representation, not tuning,
   keeps allocation low.
5. **Inline scan.** One left-to-right pass per block's content using a
   256-entry table of the special bytes `` \n ` \ & < * _ [ ] ! ``; a
   plain-text run is located by skipping non-special bytes and becomes one
   text node. O(C) for the scan.
6. **Code spans.** Use the backtick memo of SPEC.md: an array indexed by
   run length (1..100) holding the start of the run of that length most
   recently met by any closer search (overwritten, not maximised), plus a
   flag set once a search has reached the end of the content. O(C) per
   block in total.
7. **Delimiter stack.** Entries form a doubly linked list so that
   removing any entry, and removing all entries strictly between an opener
   and a closer, costs O(1) per removed entry. Delimiter and bracket
   entries are small records in a growable array reused (cleared) for
   every block and linked by indices, not individually heap-allocated
   objects.
   Process emphasis uses the 12 `openers_bottom` bounds from SPEC.md. Total
   emphasis work is O(C) amortised.
8. **Emphasis and link wrapping.** Wrapping the nodes between opener and
   closer text nodes in a new emph, strong, link or image node is done by
   relinking sibling pointers, O(1) per node moved. Each node is moved
   only by the wrap that directly encloses it.
9. **Bracket stack.** A stack of entries {image flag, text node, position}
   plus the single `link_closed` flag. A `]` costs O(1) unless `(` follows;
   destination and title are scanned in place on the content with the
   byte-level scanners of SPEC.md (the title scanner tracks the reachable
   positions of the "longest match" rule with a constant amount of state)
   and decoded only once the link has succeeded.
10. **Rendering.** An iterative walk over parent/next/first-child links
    with an entering/exiting flag (inline nesting reaches thousands of
    levels, so recursion is not used for inlines). Image alt text is
    produced in the same walk by a plain-text mode that is on while inside
    an image, so every node is visited once. HTML escaping and href
    encoding copy unescaped stretches in bulk and use a lookup table for
    the characters that change. Output goes into one growable byte buffer
    (grown geometrically, optionally pre-sized to a small multiple of N)
    and is written with a single write. Cost O(nodes + output size).

Overall the program is O(N + L·D) time and O(N) memory, with a small
constant number of allocations per inline node at most.

## Left to the implementer

- Exact container types, struct/record layout, field names, the choice
  between index arenas and chunked pools, and module structure.
- Whether inlines are parsed in a pass after all blocks close or when each
  leaf block closes.
- Whether adjacent text nodes are merged (output is the same).
- How line views are represented (index pairs, slices, pointers) and
  whether the current line is copied into a scratch buffer.
- Micro-optimisations: table-driven character classes, bulk search for
  the next special byte, pre-sizing buffers, integer formatting of list
  start numbers.

## Pitfalls

- Allocating every node as an individual heap object that carries all
  block and inline fields: memory traffic and garbage-collection work grow
  several-fold (tens of megabytes allocated for a 1 MB input).
- Copying text for each text node, or allocating a scratch buffer per
  entity, escape or delimiter run, when a span into the content suffices.
- Storing children in arrays and inserting or removing by shifting
  elements, or erasing delimiter entries from the middle of an
  array-backed stack: emphasis and link wrapping become quadratic in C.
- Searching for a closing backtick run from scratch at every opening run
  without the per-length memo (quadratic on paragraphs with many unmatched
  runs).
- Walking process-emphasis openers back to the stack bottom instead of the
  `openers_bottom` bound for the closer's kind (quadratic on long runs of
  unmatched `*`/`_`).
- Building the output by repeated concatenation of immutable strings,
  building per-node strings and joining them up a recursive render, or
  issuing one write per node.
- Re-joining or re-slicing a paragraph's content into new strings per
  inline (e.g. passing the "rest of the content" as a fresh copy to a
  scanner); scanners take the content and a position.
- Running backtracking patterns, or patterns on extracted substrings, in
  per-line block scanners; or recursing over the inline tree.
- Rendering each image's alt text with a separate walk of its
  descendants: nested images are then walked once per enclosing image.
