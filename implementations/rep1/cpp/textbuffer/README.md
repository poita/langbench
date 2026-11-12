# textbuffer

A small C++20 library implementing the editing core of a text editor: a
document of lines, multiple cursors (each with an optional selection),
insertion and deletion at every cursor, cursor movement with a remembered goal
column, and undo/redo. A thin command-line tool drives it from a script on
stdin.

Only the standard library is used (GoogleTest for the tests).

## Design

- The document is a `std::vector<std::string>` of lines. A replacement costs
  O(line length + inserted length), plus O(lines) when lines are added or
  removed.
- A multi-cursor edit visits the cursors once, in order. Cursors not yet
  visited are mapped through the composed effect of earlier replacements in
  O(1) (`Shift` in `src/editor.cpp`), so the cursor work is O(C).
- Normalization (merging colliding cursors) is a stable sort (skipped when the
  cursors are already ordered) plus one merge sweep.
- Each changing edit pushes one undo entry holding the cursors before/after and
  the list of replacements `(start, removed, inserted)`; never a copy of the
  document. Undo replays them in reverse with the texts swapped, redo in order.

### Modules

| Header | Responsibility |
|---|---|
| `position.hpp` | `Position` (line, column) and `advance()` over text |
| `document.hpp` | `Document`: lines, clamping, `textBetween`, `replace` |
| `cursor.hpp` | `Cursor` and `normalize()` |
| `movement.hpp` | `moveCursor()` and `Direction` |
| `editor.hpp` | `Editor`: document + cursors + undo/redo |
| `command.hpp` | `Command`, `parseCommand()`, `execute()` |
| `script.hpp` | `runScript()`: the whole stdin format |

## Build

Requires CMake >= 3.20, a C++20 compiler and GoogleTest (for the tests).

```sh
./build.sh                         # Release build into ./build
ctest --test-dir build             # run the unit tests
cmake -S . -B build -DTEXTBUFFER_BUILD_TESTS=OFF   # library and CLI only
```

## Command-line tool

`./run.sh` reads a script on stdin and writes the output of each `print` to
stdout. The script is a line with `N`, then `N` document lines (verbatim), then
one command per line:

```
insert <text>       (\n = newline, \\ = backslash)
delete | delete-forward
move left|right|up|down|home|end [select]
goto <line> <col> | add-cursor <line> <col> | clear-cursors
undo | redo | print
```

`print` writes the document, one `cursor <line> <col>` line per cursor, and
`--`. See the problem's `SPEC.md` for the exact semantics.

```sh
printf '1\nabc\nmove end\ninsert d\\ne\nprint\nundo\nprint\n' | ./run.sh
```

## Library example

```cpp
#include <iostream>
#include "textbuffer/editor.hpp"

int main() {
    using namespace textbuffer;
    Editor ed(Document::fromText("alpha\nbeta\ngamma"));
    ed.addCursor(1, 0);
    ed.addCursor(2, 0);
    ed.insert("- ");                 // one edit at all three cursors
    ed.move(Direction::End, true);   // select to the end of each line
    ed.insert("X");
    ed.print(std::cout);
    ed.undo();                       // reverts the whole multi-cursor insert of "X"
    std::cout << ed.document().text() << '\n';
}
```

Link against the `textbuffer::textbuffer` CMake target.
