# textbuffer

The editing core of a text editor, as a Rust library and a small command-line tool:
a document made of lines, any number of cursors (each optionally holding a selection),
insertion and deletion at every cursor, cursor movement with a remembered goal column,
and undo/redo. Standard library only.

* Text is printable ASCII, so a column is both a character index and a byte index.
* The document is a `Vec` of lines: an edit costs `O(line length)`, adding or removing
  lines `O(number of lines)`.
* A multi-cursor edit does `O(cursors)` cursor work: each cursor is mapped through the
  shift of the replacement before it in `O(1)`.
* Cursors that collide are merged after every command (stable sort plus one sweep).
* Undo entries hold the cursors before and after the command and its replacements
  (start, removed text, inserted text), never document copies.

## Building

```
cargo build --release      # or ./build.sh
cargo test                 # unit, integration, differential and doc tests
```

The binary is `target/release/textbuffer-cli`; `./run.sh` runs it from any directory.

## Command-line tool

It reads a script on stdin and writes the output of every `print` command to stdout.

```
N                 number of initial document lines (0 means one empty line)
<N lines>         the document, verbatim (may be empty, may look like a command)
<commands>        one per line until end of input
```

| command | effect |
|---|---|
| `insert <text>` | insert at every cursor, replacing selections; `\n` is a newline, `\\` a backslash |
| `delete` / `delete-forward` | backspace / forward delete (selections are deleted whole) |
| `move <left\|right\|up\|down\|home\|end> [select]` | move every cursor, optionally extending selections |
| `goto <line> <col>` | collapse to one primary cursor (out-of-range values are clamped) |
| `add-cursor <line> <col>` | add a cursor (merged if it lands inside another) |
| `clear-cursors` | keep only the primary cursor |
| `undo` / `redo` | one step per edit command |
| `print` | write the lines, then `cursor <line> <col>` per cursor, then `--` |

Example:

```
$ printf '2\nhello\nworld\nmove end\ninsert !\nadd-cursor 1 5\ninsert ?\nprint\n' | ./run.sh
hello!?
world?
cursor 0 7
cursor 1 6
--
```

Exit status is 0 on success; malformed input is reported on stderr with status 1.
The full format is in the problem's `SPEC.md`.

## Library

```rust
use textbuffer::{Buffer, Direction, Position};

let mut buf = Buffer::from_text("alpha\nbeta\ngamma");
buf.add_cursor(1, 0);
buf.add_cursor(2, 0);
buf.insert("- ").unwrap();                     // one edit, three cursors
assert_eq!(buf.text(), "- alpha\n- beta\n- gamma");

buf.move_cursors(Direction::End, true);        // select to end of each line
buf.insert("X").unwrap();                      // replaces the selections
assert_eq!(buf.text(), "- X\n- X\n- X");

buf.undo();                                    // reverts the whole command
assert_eq!(buf.text(), "- alpha\n- beta\n- gamma");
assert_eq!(buf.cursors().len(), 3);
assert_eq!(buf.cursors()[0].anchor, Some(Position::new(0, 2)));
```

Modules: `position` (`Position`), `document` (`Document`, the splice primitive),
`cursor` (`Cursor`, `normalize`), `history` (undo/redo entries), `buffer` (`Buffer`),
`command` (parsing of the command language) and `script` (running a whole input script,
which is all the CLI does). Run `cargo doc --open` for the API documentation.

## Tests

Besides unit tests in each module, `tests/` has the worked examples of the specification,
end-to-end tests of the binary, and a differential test that compares `Buffer` against a
naive offset-based model on thousands of random command sequences.
