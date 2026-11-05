# textbuffer

The editing core of a text editor, as a D library plus a small command-line
driver: a document made of lines, any number of cursors (each with an optional
selection), insertion and deletion at every cursor, cursor movement with a
remembered goal column, and undo/redo.

* Lines are stored in a gap buffer of mutable line buffers, so a multi-cursor
  edit costs O(cursors) plus the size of the text it touches.
* Positions are `(line, column)` pairs throughout; nothing is converted to a
  document offset.
* Only the D standard library is used.

The behaviour is specified in `problems/textbuffer/SPEC.md` of the task
repository (document model, cursor normalisation, edit rules, the script
language below).

## Layout

| path | purpose |
|---|---|
| `source/textbuffer/position.d` | `Pos`, text-shape helpers |
| `source/textbuffer/cursor.d` | `Cursor`, normalisation (sorting and merging) |
| `source/textbuffer/lines.d` | `Line`, `LineStore` (gap buffer of lines, splice) |
| `source/textbuffer/history.d` | undo entries, `Stack` |
| `source/textbuffer/buffer.d` | `TextBuffer`, the public editing API |
| `source/textbuffer/script.d` | the command language used by the CLI |
| `source/textbuffer/vec.d` | growable array / character buffer |
| `source/textbuffer/package.d` | `import textbuffer;` re-exports everything |
| `app/main.d` | the command-line tool |
| `tests/` | unit tests (separate from the library sources) |

## Build

Requires LDC and dub (developed with LDC 1.41.0, dub 1.40.0).

```sh
./build.sh          # dub build -b release --compiler=ldc2 -c cli  ->  bin/textbuffer
dub test --compiler=ldc2
```

`dub build -c library` builds only the library.

## Command-line use

`./run.sh` reads a script on stdin and writes the output of its `print`
commands to stdout.

The script starts with a line holding the number `N` of initial document
lines, followed by those `N` lines verbatim; every remaining line is a command:

| command | effect |
|---|---|
| `insert <text>` | insert at every cursor, replacing selections (`\n` = newline, `\\` = backslash) |
| `delete` / `delete-forward` | backspace / delete at every cursor, or delete the selections |
| `move left\|right\|up\|down\|home\|end [select]` | move every cursor, optionally extending selections |
| `goto <line> <col>` | one cursor at the (clamped) position |
| `add-cursor <line> <col>` | add a cursor |
| `clear-cursors` | keep only the primary cursor |
| `undo`, `redo` | one step per edit command |
| `print` | write the document, a `cursor <line> <col>` line per cursor, then `--` |

```console
$ printf '2\nhello world\nsecond line\nmove end\ninsert !\ngoto 0 5\ninsert ,\nprint\n' | ./run.sh
hello, world!
second line
cursor 0 6
--
```

A malformed script makes the tool print a message on stderr and exit with
status 1 (output produced before the error is still written).

## Library use

```d
import textbuffer;

auto buf = TextBuffer.fromText("alpha\nbeta\ngamma");
buf.addCursor(1, 0);
buf.addCursor(2, 0);
buf.insert("- ");
assert(buf.text == "- alpha\n- beta\n- gamma");

buf.move(Direction.end, true);   // select to the end of each line
buf.insert("X");
assert(buf.text == "- X\n- X\n- X");

buf.undo();
assert(buf.text == "- alpha\n- beta\n- gamma");
buf.redo();

CharBuf output;
buf.render(output);              // document, cursor lines and "--"
```

The main entry point is `TextBuffer`: `insert`, `deleteBackward`,
`deleteForward`, `move`, `goTo`, `addCursor`, `clearCursors`, `undo`, `redo`,
and the queries `text`, `line`, `lineCount`, `cursors`, `canUndo`, `canRedo`,
`clamp`. Positions given to the API are clamped, so calls cannot fail.
`textbuffer.script.runScript` runs a whole script and is what the CLI uses.
