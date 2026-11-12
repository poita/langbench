# commonmark: required approach

SPEC.md defines what the program must output; this note defines how it computes
it. Where the two seem to disagree, SPEC.md wins.

Sizes: `N` is the input size (at most 1 MB), `L` the number of lines, `D ≤ 300`
the block nesting depth, `C` the length of one paragraph's or heading's
content.

## Algorithm

A cmark-style two-phase converter. The block phase reads the input line by line,
matching each line against the chain of open blocks, opening new blocks and
adding the rest of the line to the open leaf block. Once the block tree is
complete, each paragraph's and heading's content is parsed left to right into
inline nodes with SPEC.md's delimiter stack, bracket stack and process-emphasis
algorithm. One walk over the finished tree writes the HTML, image alt text
included.

## Required rules

1. **Scanners cost what they examine.** Block and inline scanners work from a
   position in the line or content, at a cost proportional to the characters
   they look at, never to the rest of the line or content.
2. **Use the backtick memo of SPEC.md** for code spans and the
   `openers_bottom` bounds for process emphasis; no unbounded rescans.
3. **O(1) per element moved.** Removing a delimiter entry, removing all entries
   between an opener and a closer, and wrapping nodes in an emphasis, link or
   image node each cost O(1) per entry or node moved, independent of how many
   siblings remain.
4. **Deep nesting.** Inline nesting can be several thousand levels deep, which
   parsing and rendering must handle.

## Complexity

The block phase is O(N + L·D). Inline parsing is O(C) amortised per block,
including code-span search, bracket handling and emphasis. Rendering is
O(nodes + output size), each node visited once. The whole run is
O(N + L·D).
