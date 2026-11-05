# textbuffer — required approach

SPEC.md defines what the program does. This note defines how it is built. Where
the two seem to disagree, SPEC.md wins.

## Overall approach

Read all of standard input with one bulk read and walk it line by line as
views into that buffer. The document is an array of mutable per-line byte
buffers, stored as a **gap buffer of lines** so that inserting or removing
lines at a sequence of ascending (or descending) line indices costs one
sweep over the array rather than one shift per edit. Cursors are a flat array
of small value records in cursor order. A multi-cursor edit walks the cursors
once, applies each replacement in place, and maps each later cursor into the
current document lazily with a **composed shift**, so the edit is linear in
the cursor count. Each edit command pushes one undo entry (cursor snapshots
plus replacement records); undo and redo replay the replacement records
through the same splice routine. All output goes into one buffer that is
written once at the end.

Sizes below: `L` is the current number of lines, `C` the number of cursors,
`ℓ` the length of the line being edited, `m` the length of inserted or removed
text.

## Required choices

1. **Input, O(input).** One bulk read of stdin into one byte buffer; lines are
   (start, end) views found by scanning for `\n` (the last line may lack
   one). Initial document lines are copied once into their own mutable
   buffers. Commands are dispatched on their whole first word by direct byte
   comparison (`delete` and `delete-forward` share a prefix); numbers are
   parsed straight from the line view without building intermediate strings
   (a manual digit loop, or the standard integer parser where the language
   has no cheaper route), and clamped as SPEC.md describes. The `insert`
   argument is decoded once per command, with a fast path that takes
   the raw slice unchanged when it contains no backslash.
2. **Line storage: gap buffer of line buffers.** The document is one array of
   line slots with a gap (a run of unused slots). Line `i` is slot `i` if
   `i < gapStart`, otherwise slot `i + gapLen`. A replacement whose line count
   changes first moves the gap to the edited line (moving only the slots
   between the old and new gap position), then consumes or widens the gap;
   when the gap is empty the array grows geometrically. Replacements that stay
   within one line do not move the gap. Because one command's replacements
   are applied in ascending line order (and undo in descending order), the
   gap moves monotonically and a whole multi-cursor command moves O(L + lines
   added or removed) slots in total, instead of O(C·L).
3. **Line edits in place, O(ℓ + m).** Each line is a mutable growable byte
   buffer. A replacement inside one line with no newline in the text is one
   splice of that buffer (shift the tail, copy the text), reusing its
   capacity. A replacement that spans lines or inserts newlines reuses the
   first line's buffer in place (truncate at the start column, append the
   first piece, and, when the text has no newline, the suffix of the last
   affected line), creates one buffer for the last piece plus that suffix and
   one per inserted middle line, and replaces the affected slots via item 2,
   so the moved suffix is copied once. Removed text is extracted into one
   buffer only when the removed range is non-empty.
4. **Multi-cursor edit with a composed shift, O(C) cursor work per command.**
   Process cursors in cursor order. Positions of cursors not yet processed
   stay in the coordinates they had before the command; a pair `(A, B)` maps
   them to the current document: `A` is the end of the last replaced range in
   those original coordinates, `B` the position just after its replacement in
   current coordinates. A position `p` maps to `(B.line, B.col + p.col −
   A.col)` if `p.line = A.line`, otherwise to `(p.line + B.line − A.line,
   p.col)`. Before cursor `i`'s turn, map its head and anchor; after its
   replacement of `[s, e]`, set `A` to `e` mapped back to original
   coordinates with the inverse of the current pair (before updating it) and
   `B` to the new head. The pair starts as the identity `((0,0), (0,0))`; a
   cursor that makes no replacement (`delete` at `(0, 0)`, `delete-forward`
   at the document end) is still mapped but leaves the pair unchanged. This
   is exact because every later position is at or after `A`. Never loop over
   the later cursors after each replacement.
5. **Positions are (line, col) pairs throughout.** Clamping, movement,
   comparison and replacement work directly on line/column; no position is
   converted to an absolute document offset (that costs O(L) per conversion
   or an index that must be maintained under edits).
6. **Normalization, O(C log C) worst case, O(C) when already ordered.** One
   stable sort by (start ascending, end descending), then one merge sweep
   that writes surviving cursors into a reused array (in place or into a
   second buffer swapped with the first). Edits, undo, redo, in-order
   `add-cursor` and most moves leave cursors already ordered, so an O(C)
   sortedness check runs first and the sort is skipped when it passes. Merged
   cursors are never removed from the middle of the array one at a time.
7. **Undo entries.** One entry per changing edit command: the cursor array
   before the command, the cursor array after normalization (both as plain
   copies of value records), and the list of replacements `(start, removed,
   inserted)`. The inserted text of an `insert` command is stored once and
   shared by all of that command's replacements; it is not copied per cursor.
   Undo applies the replacements in reverse order, each replacing the span
   `[start, end of inserted text]` by the removed text; redo applies them in
   order, replacing `[start, end of removed text]` by the inserted text. Both
   use the routine of item 3, and restoring cursors is an O(C) copy of the
   stored snapshot (copy, so later in-place cursor changes cannot corrupt the
   entry). Clearing the redo stack is a truncation of the stack array.
8. **Goal columns.** Reset by one O(C) pass after each command that requires
   it.
9. **Output.** Append every printed line, its `\n`, and the cursor lines into
   one growable output buffer, formatting integers by hand or with the
   cheapest standard integer-to-text routine the language offers; write the
   buffer to stdout once at the end (or through one large buffered writer).

## Left to the implementer

- Exact container types, cursor record layout (explicit flag versus optional
  anchor), integer widths, and how the gap buffer exposes indexing.
- Whether the composed shift is kept as a pair of positions or as equivalent
  line/column deltas.
- The stable sort used, and whether `add-cursor` inserts by binary search
  instead of appending and normalizing (the result must be identical).
- How removed texts are stored: one buffer per non-empty removed range, or
  one byte arena per undo entry with (offset, length) records.
- Module structure, naming, error handling for malformed input.
- Micro-optimisations: capacity hints, fast paths for single-cursor commands,
  reusing scratch buffers across commands.

## Pitfalls

- Shifting every later cursor after each replacement. That is O(C²) per
  multi-cursor command (about two million position updates per edit at the
  2 000-cursor limit) and dominates the column-editing workload; use item 4.
- Inserting or erasing lines in the middle of a plain contiguous array once
  per cursor. With thousands of cursors on tens of thousands of lines each
  command shifts the array thousands of times; use the gap of item 2.
- Rebuilding a whole line, or the whole document text, for every edit, or
  using an immutable string type in a way that copies a long line more than
  once per edit. Lines can be up to 200 000 characters long and are edited
  tens of thousands of times.
- Allocating a fresh buffer for every line touched by an edit, for every
  empty removed range, or for every per-cursor copy of the inserted text.
  These allocations multiply by the cursor count and by 100 000 commands.
- Growing arrays one element at a time through an append operation whose
  cost is not amortized constant, or accumulating stdin by repeated
  concatenation of chunks.
- Splitting every command into a freshly allocated array of words; dispatch
  on the first word and slice the arguments from the line view.
- Reaching mutable program state through globals that the language makes
  thread-local, or through indirections it cannot keep in registers, inside
  the per-cursor loops. Keep the document, cursor array and shift state in
  locals or one context object passed by reference.
- Formatting output with a separate unbuffered or locked write per line, or
  building each printed line as a temporary string before copying it.
