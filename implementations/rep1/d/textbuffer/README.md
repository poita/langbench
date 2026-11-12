# textbuffer

The editing core of a text editor, as a D library plus a small command-line tool:
a document made of lines, any number of cursors (each optionally holding a
selection), insertion and deletion at every cursor, cursor movement with a
remembered goal column, and undo/redo.

* Document: lines of printable ASCII, joined by `\n`; positions are `(line, col)`.
* Cursors merge automatically when their ranges collide; they are always kept in
  order and exactly one is primary.
* Undo entries store replacements (position, removed text, inserted text) and the
  cursor sets before and after the command, never copies of the document.
* A multi-cursor edit does O(C) cursor work: each cursor is mapped through the
  composed shift of the replacements before it in O(1). Lines live in a gap
  buffer, so an edit run that sweeps through the document shifts lines once.

The behaviour is specified in full in `SPEC.md` of the task this was written for;
the design follows `APPROACH.md`.

## Requirements

LDC (tested with 1.41.0) and dub (tested with 1.40.0). Only the D standard
library is used; tests use D's built-in `unittest` blocks.

## Build

```sh
dub build -b release --compiler=ldc2     # produces bin/textbuffer
# or simply
./build.sh
```

Run the tests with

```sh
dub test --compiler=ldc2
```

## Command-line tool

`bin/textbuffer` (or `./run.sh`) reads a script on stdin and writes to stdout.

Input: a line with the number `N` of document lines, the `N` document lines
verbatim, then one command per line.

| command | effect |
|---|---|
| `insert <text>` | insert at every cursor, replacing selections (`\n` = newline, `\\` = backslash) |
| `delete` / `delete-forward` | backspace / delete a selection or one character |
| `move <left\|right\|up\|down\|home\|end> [select]` | move every cursor, optionally extending selections |
| `goto <line> <col>` | a single cursor at the (clamped) position |
| `add-cursor <line> <col>` | add a cursor |
| `clear-cursors` | keep only the primary cursor |
| `undo` / `redo` | one step per edit command |
| `print` | write the lines, then `cursor <line> <col>` per cursor, then `--` |

```console
$ printf '2\nhello world\nsecond line\nmove end\ninsert !\ngoto 0 5\ninsert ,\nprint\n' | ./run.sh
hello, world!
second line
cursor 0 6
--
```

Malformed input is reported on stderr (exit status 1); output produced before the
error is still written.

## Library

The package `textbuffer` re-exports everything; the modules are split by
responsibility:

| module | contents |
|---|---|
| `textbuffer.pos` | `Pos`, a `(line, col)` position |
| `textbuffer.line` | `Line`, a growable in-place-editable line |
| `textbuffer.document` | `Document`, the gap-buffered array of lines, and range replacement |
| `textbuffer.cursor` | `Cursor` and `normalize`, the merge of colliding cursors |
| `textbuffer.history` | `Replacement`, `UndoEntry`, `History` |
| `textbuffer.buffer` | `TextBuffer`: edits, movement, cursors, undo/redo |
| `textbuffer.script` | the command language used by the CLI (`parseCommand`, `runScript`) |

To use it as a dependency, add `dependency "textbuffer" version="*"` (using its
`library` configuration, which leaves out the CLI) and:

```d
import textbuffer;

void main()
{
    auto buf = new TextBuffer(["alpha", "beta", "gamma"]);

    buf.addCursor(1, 0);
    buf.addCursor(2, 0);
    buf.insert("- ");                 // one edit, three cursors
    assert(buf.text == "- alpha\n- beta\n- gamma");

    buf.move(Direction.end, true);    // select to the end of each line
    buf.insert("X");
    assert(buf.text == "- X\n- X\n- X");

    buf.undo();                       // reverts the whole multi-cursor edit
    assert(buf.text == "- alpha\n- beta\n- gamma");
    assert(buf.cursors.length == 3);
    buf.redo();
}
```

Positions passed to `goTo` and `addCursor` are clamped to the document.
