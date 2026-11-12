# textbuffer

The editing core of a text editor, as a small pure-Python library plus a
command-line driver: a document made of lines, any number of cursors (each
with an optional selection and a remembered goal column), insertion and
deletion at every cursor, cursor movement, and undo/redo. Standard library
only (Python 3.12+; developed on 3.14).

## Layout

| module | responsibility |
|---|---|
| `textbuffer.document` | `Document`: list of lines, `(line, col)` positions, range `replace` |
| `textbuffer.cursor` | `Cursor`, and `normalize` (stable sort + merge of colliding cursors) |
| `textbuffer.history` | `Replacement`, `UndoEntry`, `History` (undo entries store edits, never document copies) |
| `textbuffer.buffer` | `TextBuffer`: the editing commands, movement, cursor management, undo/redo |
| `textbuffer.commands` | the textual command language (`Interpreter`, `parse_input`, `decode_text`) |
| `textbuffer.cli` | the stdin/stdout tool |

A multi-cursor edit does O(cursors) cursor work: later cursors are mapped
through the composed shift of the earlier replacements in O(1) each. A
replacement costs O(line length + text length), plus O(lines) when lines are
added or removed.

## Build

```
./build.sh        # byte-compiles src/; there is nothing else to build
```

No install step is needed; `run.sh` sets `PYTHONPATH` to `src/`. (`pip install .`
also works and provides a `textbuffer` console script.)

## Command-line use

```
./run.sh < input
```

Input: a line count `N`, then `N` document lines (verbatim), then one command
per line. Output: for every `print`, the document, one `cursor <line> <col>`
line per cursor, and `--`. Commands: `insert <text>` (`\n` = newline, `\\` =
backslash), `delete`, `delete-forward`, `move <left|right|up|down|home|end>
[select]`, `goto <line> <col>`, `add-cursor <line> <col>`, `clear-cursors`,
`undo`, `redo`, `print`. Coordinates are clamped. The exact semantics are in
the problem's `SPEC.md`.

```
$ printf '1\nabc\nmove end\ninsert d\\ne\nprint\nundo\nprint\n' | ./run.sh
abcd
e
cursor 1 1
--
abc
cursor 0 3
--
```

A malformed command stops the program with a message on stderr and exit
status 1 (output produced so far is kept).

## Library use

```python
from textbuffer import TextBuffer

buf = TextBuffer("alpha\nbeta\ngamma")
buf.add_cursor(1, 0)
buf.add_cursor(2, 0)
buf.insert("- ")                 # one edit, three cursors
buf.move("end", select=True)     # select to end of each line
buf.insert("X")
print(buf.text)                  # "- X\n- X\n- X"
print([c.head for c in buf.cursors])   # [(0, 3), (1, 3), (2, 3)]

buf.undo()                       # reverts the whole multi-cursor edit
buf.redo()
print(buf.render())              # document, cursor rows and "--"
```

`TextBuffer` methods: `insert`, `delete`, `delete_forward`, `move`, `goto`,
`add_cursor`, `clear_cursors`, `undo`, `redo`; properties `text`, `lines`,
`cursors`, `can_undo`, `can_redo`; `render()`. `insert` takes real text
(newlines as `"\n"`); escape decoding belongs to the command layer.

## Tests

```
python3 -m pytest          # from this directory; pythonpath is configured
```

Includes unit tests per module and a randomised comparison against a naive
offset-based model written directly from the spec.
