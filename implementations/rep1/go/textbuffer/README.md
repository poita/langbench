# textbuffer

`textbuffer` is a small Go library implementing the editing core of a text
editor, plus a command-line tool that drives it from a script:

- a document made of lines of printable ASCII;
- any number of cursors, each optionally holding a selection (forward or
  backward) and a goal column for vertical movement;
- insertion, backspace and forward-delete applied at every cursor at once,
  with colliding cursors merged;
- cursor movement (`left`, `right`, `up`, `down`, `home`, `end`), with or
  without extending the selection;
- undo and redo, where one step is one edit command however many cursors took
  part.

It uses only the Go standard library.

## Layout

| path | contents |
|---|---|
| `*.go` (package `textbuffer`) | the library: `Buffer`, `Cursor`, `Position`, `Direction` |
| `document.go` | line storage and splice operations |
| `edit.go` | multi-cursor edits and the O(1) cursor shift mapping |
| `movement.go` | cursor movement and goal columns |
| `normalize.go` | sorting and merging of colliding cursors |
| `history.go` | undo/redo entries (replacements and cursor sets, never document copies) |
| `internal/script` | parser/interpreter of the command language and `print` formatter |
| `cmd/textbuffer` | the command-line tool (a thin wrapper around `internal/script`) |

## Build

```sh
./build.sh        # go build -o bin/textbuffer ./cmd/textbuffer
./run.sh < input  # runs bin/textbuffer
go test ./...     # run the tests
```

Go 1.27.1 or newer is required.

## Command-line tool

The tool reads a script from standard input and writes to standard output.

```
N                  number of initial document lines (0 = one empty line)
<N lines>          the document, verbatim
<commands>         one command per line until end of input
```

| command | effect |
|---|---|
| `insert <text>` | insert at every cursor, replacing selections; in `<text>`, `\n` is a newline and `\\` a backslash |
| `delete` | backspace |
| `delete-forward` | delete the character after each cursor |
| `move <dir> [select]` | `dir` is `left`, `right`, `up`, `down`, `home` or `end` |
| `goto <line> <col>` | a single cursor at the (clamped) position |
| `add-cursor <line> <col>` | add a cursor at the (clamped) position |
| `clear-cursors` | keep only the primary cursor |
| `undo`, `redo` | step through the edit history |
| `print` | write the document, then `cursor <line> <col>` per cursor, then `--` |

Nothing is written except by `print`. On a malformed command the tool prints
a message to standard error and exits with status 1 (output produced before
the error is still written).

```console
$ printf '3\nalpha\nbeta\ngamma\nadd-cursor 1 0\nadd-cursor 2 0\ninsert - \nprint\n' | ./run.sh
- alpha
- beta
- gamma
cursor 0 2
cursor 1 2
cursor 2 2
--
```

## Library example

```go
package main

import (
	"fmt"

	"textbuffer"
)

func main() {
	b := textbuffer.New("alpha\nbeta\ngamma")

	// Three cursors, one at the start of each line.
	b.AddCursor(1, 0)
	b.AddCursor(2, 0)
	b.Insert("- ")
	fmt.Println(b.Text()) // "- alpha\n- beta\n- gamma"

	// Select to the end of every line and replace the selections.
	b.Move(textbuffer.End, true)
	b.Insert("X")
	fmt.Println(b.Text()) // "- X\n- X\n- X"

	// One undo reverts the whole multi-cursor edit.
	b.Undo()
	fmt.Println(b.Text()) // "- alpha\n- beta\n- gamma"

	for _, c := range b.Cursors() {
		fmt.Println(c.Head.Line, c.Head.Col)
	}
}
```

### API overview

- `New(text)`, `NewFromLines(lines)` create a buffer with one primary cursor at
  `(0, 0)`.
- Editing: `Insert`, `Delete`, `DeleteForward`; history: `Undo`, `Redo`,
  `CanUndo`, `CanRedo`.
- Cursors: `Move(dir, extend)`, `GoTo`, `AddCursor`, `ClearCursors`,
  `Cursors`, `Primary`, `CursorCount`, `SelectedText`.
- Reading: `Text`, `Lines`, `Line`, `LineLen`, `LineCount`, `WriteTo`.

Positions and cursors are `Position{Line, Col}` and `Cursor{Head, Anchor,
Selected, Primary, Goal}`; columns are byte indexes. See the package
documentation (`go doc textbuffer`) for the exact semantics, including how
colliding cursors are merged and how goal columns behave.

## Design notes

- Lines are byte slices, so an edit inside a line is an in-place splice
  (O(line length + text length)); adding or removing lines costs O(number of
  lines).
- A multi-cursor edit visits the cursors once, in order. Each not-yet-visited
  cursor is mapped through the composed effect of the earlier replacements in
  O(1) (a line delta plus a column delta for the line where the last
  replacement ended), so the cursor work of an edit is O(C).
- Undo entries hold the cursor sets before and after plus the list of
  replacements `(start, removed text, inserted text)`; undo replays them in
  reverse with the texts swapped, redo replays them forwards.
- Cursor normalization is a stable sort followed by a single merge sweep,
  O(C log C).
- `model_test.go` contains a deliberately naive offset-based reference model;
  a randomized test checks that `Buffer` agrees with it after every command.
