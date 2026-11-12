# textbuffer — Text buffer with undo, redo and multiple cursors

Implement the editing core of a text editor: a document made of lines, a set
of cursors (each optionally holding a selection), insertion and deletion at
every cursor, cursor movement with a remembered goal column, and undo/redo.
Read an initial document and a sequence of commands from stdin; for every
`print` command write the document and the cursor positions to stdout.

The largest workloads are 100 000 commands on a 10 000-line document, and
20 000 edits inside lines of 200 000 characters. A straightforward array of
line strings with O(line length) edits and O(number of lines) line
insertions is sufficient; ropes or piece tables are not required.

## Document and positions

The document is a sequence of `L ≥ 1` lines. Each line is a string of
printable ASCII characters (bytes 0x20 `space` .. 0x7E `~`), possibly empty.
Line text never contains tabs, newlines or non-ASCII bytes, so a column is
both a character index and a byte index. Lines are joined by single newline
characters: the *text* of the document is `line[0] + "\n" + line[1] + ... +
line[L-1]`, with no trailing newline. An empty document is one empty line.

A **position** is a pair `(line, col)` with `0 ≤ line < L` and `0 ≤ col ≤
len(line)`. Positions are 0-based. `col = len(line)` is the end of that line
(just before the newline that joins it to the next line, or the end of the
document on the last line). Positions are ordered lexicographically: first by
line, then by column. Equivalently each position corresponds to a character
**offset** into the document text (the newline counts as one character):
`offset(line, col) = col + Σ_{i<line} (len(line[i]) + 1)`. The offset view is
useful for stating the editing rules below; implementations may work in
either representation.

## Cursors

A cursor has:

- a **head** position (where the caret is);
- an optional **anchor** position, present only when the cursor has a
  **selection**. When present the anchor is never equal to the head; a
  cursor whose anchor would coincide with its head has no selection.
- a **primary** flag — exactly one cursor is primary at all times;
- a **goal column**, an integer used by `move up` / `move down`.

The **range** of a cursor is the pair `[start, end]` with `start =
min(head, anchor)` and `end = max(head, anchor)`; for a cursor without a
selection, `start = end = head` (an *empty* range). The selected text is the
text between offset `start` and offset `end`. A selection is **forward** when
`head = end` (anchor before head) and **backward** when `head = start`.

The **cursor order** is ascending order of range start. After the
normalization described below, all cursors have distinct starts, so this
order is total; `print` lists cursors in this order and multi-cursor edits are
applied in this order.

Initial state: one cursor with head `(0, 0)`, no selection, primary, goal
column 0. The undo and redo stacks are empty.

### Normalization (merging colliding cursors)

After every command except `print`, the cursor set is normalized:

1. Sort the cursors by range start ascending; among equal starts, by range
   end **descending**; cursors with equal start *and* equal end keep their
   relative order from before the command (the sort is stable). The order
   before the command is the cursor order left by the previous
   normalization, with a cursor added by `add-cursor` placed after all
   existing cursors. This tie-break is observable: when two cursors land on
   the same range during `move up` / `move down`, the merged cursor keeps
   the goal column of the one that came first.
2. Sweep the sorted list, maintaining the current group's merged cursor
   `cur` (initially the first cursor). For each following cursor `c`:
   - if `cur` has no selection or `c` has no selection: `c` joins the group
     iff `c.start ≤ cur.end` (a point cursor anywhere within a selection's
     range, including its edges, or on another point cursor, merges);
   - otherwise (both have selections): `c` joins the group iff
     `c.start < cur.end` (two selections that merely touch end-to-start do
     **not** merge).

   When `c` joins the group, `cur` becomes: range `[cur.start, max(cur.end,
   c.end)]`; if that range is empty the cursor has no selection, otherwise it
   keeps `cur`'s direction (the direction of the group's first cursor in
   sorted order: backward means head at the new start and anchor at the new
   end, forward the reverse; a cursor without a selection counts as forward);
   primary if `cur` or `c` was primary; the goal column of `cur`. When `c`
   does not join, it starts a new group.
3. The groups' cursors, in sweep order, are the new cursor list.

Two cursors with the same start always merge (one of them contains the other),
so afterwards starts are distinct and cursor order is well defined.

### Goal column

After every command **except** `move up`, `move down` (with or without
`select`) and `print`, the goal column of every cursor is set to the column of
its head — even when the command changed nothing. `move up` / `move down`
use and keep the goal column, except at the document edges as described
under `move`.

## Input

Standard input is UTF-8 text (in fact pure ASCII). Lines are terminated by
`\n`; the final line may or may not end with a newline. There are no `\r`
characters.

- Line 1: an integer `N`, `0 ≤ N ≤ 10000`, the number of initial document
  lines. `N = 0` means the document starts as one empty line.
- Lines 2 .. N+1: the initial document, one line each, taken **verbatim**
  (leading and trailing spaces are part of the line; a line may be empty; a
  line may look like a command). Every character is printable ASCII.
- All following lines, until end of input: one command per line. There are
  no blank command lines. Command words and arguments are separated by
  exactly one space; only the `insert` command has an argument that can
  itself contain spaces.

Commands:

| command | effect |
|---|---|
| `insert <text>` | Insert text at every cursor (replacing selections). |
| `delete` | Backspace: delete each selection, or the character before each cursor. |
| `delete-forward` | Delete each selection, or the character after each cursor. |
| `move <dir>` | Move every cursor; `dir` is `left`, `right`, `up`, `down`, `home` or `end`. |
| `move <dir> select` | The same, extending (or starting) a selection. |
| `goto <line> <col>` | Replace all cursors by one primary cursor at the given position. |
| `add-cursor <line> <col>` | Add a non-primary cursor at the given position. |
| `clear-cursors` | Remove every cursor except the primary one. |
| `undo` | Revert the most recent recorded edit. |
| `redo` | Re-apply the most recently undone edit. |
| `print` | Write the document and cursor positions to stdout. |

`<line>` and `<col>` are non-negative decimal integers up to 10^9 without
leading zeros (except `0`). They may be out of range and are **clamped**:
first `line` is clamped to `[0, L-1]`, then `col` is clamped to `[0,
len(line)]` of that line.

### `insert <text>`

`<text>` is everything after the first space of the line — it may begin or
end with spaces and is never empty. It is decoded before use: the two-character
sequence `\n` (backslash, `n`) denotes a newline and `\\` (two backslashes)
denotes one backslash. No other character follows a backslash. Every decoded
character is printable ASCII or a newline. The decoded text is non-empty.

### Editing commands: `insert`, `delete`, `delete-forward`

An edit command processes the cursors one at a time **in cursor order**. For
each cursor it computes a *replacement* — a range of the current document
(possibly empty) and the string that replaces it — applies it, places the
cursor after the inserted text with no selection, and shifts the cursors that
come later in cursor order. Concretely, for a cursor with range `[s, e]` (in
the document as it is when this cursor's turn comes):

- `insert`: replace `[s, e]` with the decoded text. With no selection this
  is a plain insertion at the head.
- `delete`: with a selection, replace `[s, e]` with the empty string.
  Without a selection: if the head is `(0, 0)` nothing happens for this
  cursor; otherwise delete the one character before the head — the previous
  character on the line, or, when `col = 0`, the newline joining this line to
  the previous one (the line is appended to the previous line).
- `delete-forward`: with a selection, replace `[s, e]` with the empty
  string. Without a selection: if the head is at the very end of the document
  (`line = L-1`, `col = len(line)`) nothing happens for this cursor; otherwise
  delete the one character after the head — the next character on the line,
  or, when `col = len(line)`, the newline joining this line to the next one.

After a replacement of the text between offsets `s` and `e` by a string of
length `m`, the cursor ends with head at offset `s + m` and no selection.
Every cursor **later in cursor order** has all of its positions (head and
anchor) at offset `p ≥ e` (ranges never overlap, though a later cursor's start
may equal `e`), and each such offset becomes `p - e + s + m`. In line/column
terms: a position on the same line as the end of the replaced range keeps its
distance from that end; positions on later lines keep their column and are
shifted by the change in line count. Cursors earlier in cursor order are
never affected.

Note that a later cursor's own replacement is computed after the earlier
cursors' replacements have been applied; e.g. two adjacent point cursors at
columns 3 and 4 both doing `delete` remove the characters at columns 2 and 3
and both end up at column 2 (and are then merged by normalization).

When the whole command is done, the cursors are normalized. If the command
changed the document (at least one replacement was non-trivial: a non-empty
inserted string or a non-empty removed range), an **undo entry** is recorded
holding the cursor set as it was before the command, the cursor set after
normalization, and the list of replacements; the redo stack is then cleared.
Each replacement in that list is `(start position, removed text, inserted
text)` with the start position expressed in the document as it was
immediately before that replacement was applied (that is, after the earlier
cursors' replacements), which is exactly the coordinate system in which
`undo` (reverse order) and `redo` (forward order) re-apply them.
If the command changed nothing (e.g. `delete` with a single cursor at
`(0, 0)`), nothing is recorded and the redo stack is left untouched.

### `move <dir> [select]`

Applied to every cursor independently, then the set is normalized.

Without `select`:

- A cursor with a selection collapses: for `left` the head moves to the
  range start; for `right` it moves to the range end; in both cases no
  further movement takes place. For `up`, `down`, `home` and `end` the
  selection is dropped and the head then moves as described below.
- A cursor without a selection moves its head as described below.

With `select`: a cursor without a selection first sets its anchor to its
head; then the head moves as described below; the anchor stays. If the head
ends up equal to the anchor, the cursor has no selection.

Head movement from `(line, col)`:

- `left`: `(line, col-1)` if `col > 0`; else `(line-1, len(line[line-1]))`
  if `line > 0`; else unchanged.
- `right`: `(line, col+1)` if `col < len(line[line])`; else `(line+1, 0)`
  if `line < L-1`; else unchanged.
- `home`: `(line, 0)`. `end`: `(line, len(line[line]))`.
- `up`: if `line = 0`, the head moves to `(0, 0)` and the goal column is set
  to 0. Otherwise the head moves to `(line-1, min(goal, len(line[line-1])))`
  and the goal column is unchanged.
- `down`: if `line = L-1`, the head moves to `(L-1, len(line[L-1]))` and the
  goal column is set to that column. Otherwise the head moves to
  `(line+1, min(goal, len(line[line+1])))` and the goal column is unchanged.

`move` commands never touch the undo/redo stacks.

### `goto <line> <col>`

All cursors are discarded; the single remaining cursor is primary, has no
selection and its head is the clamped position. Never touches the undo/redo
stacks.

### `add-cursor <line> <col>`

Adds a non-primary cursor with no selection at the clamped position, then
normalizes (if the position lies within an existing cursor's range or on an
existing cursor, the sets merge and the number of cursors does not grow).
Never touches the undo/redo stacks.

### `clear-cursors`

Removes all non-primary cursors. The primary cursor keeps its selection.
Never touches the undo/redo stacks.

### `undo` and `redo`

`undo` pops the most recent undo entry (if the stack is empty nothing
happens), reverts its replacements (in reverse order, each restoring the
removed text in place of the inserted text), restores the cursor set exactly
as it was **before** that edit command (heads, anchors and primary flag), and
pushes the entry onto the redo stack. `redo` pops the most recent redo entry
(if empty nothing happens), re-applies its replacements in order, restores
the cursor set exactly as it was **after** that edit command, and pushes the
entry back onto the undo stack. One undo step is one edit command, however
many cursors took part. Cursor-only commands between an edit and its undo are
simply overridden by the restored cursor set. Both commands reset goal
columns like any other command.

### `print`

Writes every document line, each followed by `\n` (an empty line is printed
as an empty line), then one line `cursor <line> <col>` per cursor giving its
head position, in cursor order, then a line `--`. Nothing else is ever
written to stdout; if there is no `print` command the output is empty.

## Worked examples

### Example 1 — single cursor

Input:

    2
    hello world
    second line
    move end
    insert !
    move down
    insert  (edited)
    goto 0 5
    insert ,
    print
    delete
    delete
    print

Output:

    hello, world!
    second line (edited)
    cursor 0 6
    --
    hell world!
    second line (edited)
    cursor 0 4
    --

`move down` from `(0, 12)` lands on `(1, 11)` (the goal column 12 is clamped
to the line length). The inserted text ` (edited)` starts with a space.

### Example 2 — multiple cursors and selections

Input:

    3
    alpha
    beta
    gamma
    add-cursor 1 0
    add-cursor 2 0
    insert - 
    print
    move end select
    insert X
    print
    goto 0 1
    move right select
    move right select
    delete
    print

Output:

    - alpha
    - beta
    - gamma
    cursor 0 2
    cursor 1 2
    cursor 2 2
    --
    - X
    - X
    - X
    cursor 0 3
    cursor 1 3
    cursor 2 3
    --
    -
    - X
    - X
    cursor 0 1
    --

The `insert - ` line ends with a space. `move end select` selects from
column 2 to the end of each line; `insert X` replaces each selection.

### Example 3 — undo and redo

Input:

    1
    abc
    move end
    insert d\ne
    print
    delete
    delete
    print
    undo
    print
    undo
    print
    redo
    print
    insert Z
    redo
    print

Output:

    abcd
    e
    cursor 1 1
    --
    abcd
    cursor 0 4
    --
    abcd
    
    cursor 1 0
    --
    abcd
    e
    cursor 1 1
    --
    abcd
    
    cursor 1 0
    --
    abcd
    Z
    cursor 1 1
    --

The second `delete` joins the lines; the first `undo` reverts only that join
and puts the cursor back at `(1, 0)`. `insert Z` clears the redo stack, so
the final `redo` does nothing.

## Input sizes

- `N ≤ 10 000` initial lines; at most 1 000 000 commands per test.
- Initial lines are at most 3 000 000 characters long; the document text never
  exceeds 12 000 000 characters during a test. Lines may be created, joined
  and removed freely within that bound.
- At most 2 000 cursors exist at once; commands that hit every cursor are
  applied at that count (a multi-cursor edit is O(cursors) replacements).
- The undo stack can hold up to 1 000 000 entries.
- Total `print` output per test is at most about 30 MB; the largest input
  files are under 30 MB.
