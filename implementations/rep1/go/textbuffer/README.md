# textbuffer

The editing core of a text editor, as a Go library plus a small command-line
tool: a document made of lines, any number of cursors (each with an optional
selection), insertion and deletion at every cursor, cursor movement with a
remembered goal column, and undo/redo where one multi-cursor edit is one undo
step. Standard library only.

## Layout

| path | responsibility |
|---|---|
| `doc.go`, `buffer.go` | package docs; `Buffer`: construction, accessors, `Goto`, `AddCursor`, `ClearCursors` |
| `edit.go` | `Insert`, `Delete`, `DeleteForward` over all cursors (composed-shift algorithm) |
| `move.go` | `Direction` and `Move` |
| `cursor.go` | `Cursor` and normalization (sorting and merging colliding cursors) |
| `history.go` | undo/redo entries and `Undo`/`Redo` |
| `document.go`, `linestore.go` | the text: mutable line buffers in a gap buffer, and the splice routine |
| `position.go` | `Position`, and the shift mapping used by multi-cursor edits |
| `internal/script` | the command language of the CLI |
| `cmd/textbuffer` | the CLI entry point |

## Build

```
./build.sh          # writes bin/textbuffer (needs Go 1.27.1)
go test ./...       # unit tests
```

## Command-line tool

`./run.sh` (or `bin/textbuffer`) reads a script on stdin and writes to stdout.

```
N                      number of initial lines (0 = one empty line)
<N lines>              the document, verbatim
<commands...>          one per line
```

| command | effect |
|---|---|
| `insert <text>` | insert at every cursor (`\n` = newline, `\\` = backslash) |
| `delete` / `delete-forward` | backspace / delete at every cursor |
| `move left\|right\|up\|down\|home\|end [select]` | move every cursor, optionally extending selections |
| `goto <line> <col>` | a single cursor at the (clamped) position |
| `add-cursor <line> <col>` | add a cursor |
| `clear-cursors` | keep only the primary cursor |
| `undo`, `redo` | walk the edit history |
| `print` | write the document, then `cursor <line> <col>` per cursor, then `--` |

Example:

```
$ printf '1\nhello world\nmove end\ninsert !\ngoto 0 5\ninsert ,\nprint\nundo\nprint\n' | ./run.sh
hello, world!
cursor 0 6
--
hello world!
cursor 0 5
--
```

A malformed command makes the tool print `textbuffer: line N: ...` to stderr
and exit with status 1, after writing the output produced so far.

## Library

```go
package main

import (
	"fmt"

	"textbuffer"
)

func main() {
	b := textbuffer.New("alpha", "beta", "gamma")

	// Column editing: three cursors, one per line.
	b.AddCursor(1, 0)
	b.AddCursor(2, 0)
	b.InsertString("- ")
	fmt.Println(b.Text()) // "- alpha\n- beta\n- gamma"

	b.Move(textbuffer.End, true) // select to the end of every line
	b.InsertString("X")          // replace the selections
	fmt.Println(b.Text())        // "- X\n- X\n- X"

	b.Undo()              // one step undoes the edit at all three cursors
	fmt.Println(b.Text()) // "- alpha\n- beta\n- gamma"

	for _, c := range b.Cursors() {
		fmt.Println(c.Head.Line, c.Head.Col, c.HasSelection)
	}
}
```

Positions are `(Line, Col)` pairs, 0-based, with columns counting bytes
(lines are printable ASCII). `Buffer.Line(i)` returns a view that is valid until
the next modification. A `Buffer` is not safe for concurrent use.

## Design notes

* Lines are mutable byte slices held in a gap buffer, so inserting or removing
  lines at ascending line numbers costs one sweep rather than one shift per
  cursor.
* A multi-cursor edit walks the cursors once. Cursors that have not been
  processed yet keep their original coordinates and are mapped into the edited
  document through a single composed shift, so an edit is linear in the number
  of cursors.
* Cursors are re-normalized after every command: sorted (a sortedness check
  skips the sort when the cursors are already in order) and merged when they
  collide.
* An undo entry holds the cursor sets before and after the command plus the
  list of replacements; undo and redo replay them through the same splice
  routine.
