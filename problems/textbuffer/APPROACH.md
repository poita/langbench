# textbuffer: required approach

SPEC.md defines what the program does; this note defines how it computes it.
Where the two seem to disagree, SPEC.md wins.

Sizes: `L` is the current number of lines, `C ≤ 2,000` the number of cursors,
`ℓ` the length of the line being edited, `m` the length of the text inserted
or removed.

## Algorithm

The document is a sequence of lines; positions are (line, column) pairs and
cursors a sequence in cursor order. An edit command visits the cursors once, in
order, and applies each cursor's replacement to the document as a splice of the
affected lines; cursors not yet visited are mapped into the current document
through the composed effect of the replacements before them. Normalization is a
stable sort followed by one merge sweep.

Each changing edit command pushes one undo entry: the cursors before and after
the command and its replacements (start, removed text, inserted text). Undo
replays the replacements in reverse with the texts swapped, redo replays them
in order, and each restores the stored cursors.

## Required rules

1. **A multi-cursor edit does O(C) cursor work** besides its replacements:
   each cursor is mapped through the composed shift of the earlier
   replacements in O(1), never updated after every replacement.
2. **Undo entries record replacements and cursors**, never copies of the
   document.

## Complexity

A replacement costs O(ℓ + m) within a line, plus O(L) when lines are added or
removed. A multi-cursor edit does O(C) cursor work besides its replacements.
Normalization is O(C log C). Undo and redo cost the same as the command they
replay.
