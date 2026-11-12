# textbuffer

The editing core of a text editor, in Clojure: a document made of lines, any
number of cursors (each optionally holding a selection), insertion and deletion
at every cursor, cursor movement with a remembered goal column, and undo/redo.
It ships as a small library plus a command-line tool that reads a document and
a script of commands from stdin and prints the document and cursor positions.

The behaviour is specified by the textbuffer `SPEC.md`; the implementation
follows the approach in `APPROACH.md`: documents are arrays of line strings,
a multi-cursor edit applies one splice per cursor while mapping the not yet
visited cursors through a composed O(1) shift, and undo entries store only
cursors and replacements, never document copies.

Requirements: Clojure 1.12.6 (the `clojure` CLI) on Java 27. No runtime
dependencies besides Clojure itself.

## Build

```sh
./build.sh
```

This AOT-compiles the CLI into `target/classes` (which is on the classpath, so
later runs start faster). The project also runs without building:
`./run.sh` falls back to compiling the sources on load.

## Command-line tool

```sh
./run.sh < input.txt
# or: clojure -M:run < input.txt
```

Input (stdin): a line with the number `N` of document lines, then `N` lines of
document text taken verbatim, then one command per line:

| command | effect |
|---|---|
| `insert <text>` | insert at every cursor, replacing selections (`\n` = newline, `\\` = backslash) |
| `delete` / `delete-forward` | backspace / delete the selection or the character before / after each cursor |
| `move <left\|right\|up\|down\|home\|end> [select]` | move every cursor, optionally extending selections |
| `goto <line> <col>` | a single cursor at the (clamped) position |
| `add-cursor <line> <col>` | add a cursor at the (clamped) position |
| `clear-cursors` | keep only the primary cursor |
| `undo` / `redo` | revert / re-apply one edit command |
| `print` | write the document, one `cursor <line> <col>` line per cursor, and `--` |

Example:

```
$ printf '2\nhello world\nsecond line\nmove end\ninsert !\nmove down\ninsert  (edited)\ngoto 0 5\ninsert ,\nprint\n' | ./run.sh
hello, world!
second line (edited)
cursor 0 6
--
```

The exit status is 0 on success; malformed input prints a message to stderr
and exits with status 1.

## Library

```clojure
(require '[textbuffer.buffer :as buf])

(def b
  (-> (buf/from-text "alpha\nbeta\ngamma")
      (buf/add-cursor 1 0)
      (buf/add-cursor 2 0)
      (buf/insert "- ")))

(buf/lines b)             ;=> ["- alpha" "- beta" "- gamma"]
(buf/cursor-positions b)  ;=> [[0 2] [1 2] [2 2]]

(-> b (buf/move :end true) (buf/insert "X") buf/lines)
;=> ["- X" "- X" "- X"]

(-> b buf/undo buf/lines) ;=> ["alpha" "beta" "gamma"]
(print (buf/render b))    ; the snapshot the CLI's `print` command writes
```

A `Buffer` is an immutable value; every operation returns a new buffer and
leaves its argument untouched. The public API lives in `textbuffer.buffer`:
`from-text`, `from-lines`, `lines`, `text`, `cursors`, `cursor-positions`,
`insert`, `delete-backward`, `delete-forward`, `move`, `goto`, `add-cursor`,
`clear-cursors`, `undo`, `redo`, `can-undo?`, `can-redo?`, `render`,
`write-state!`.

### Modules

| namespace | responsibility |
|---|---|
| `textbuffer.buffer` | public API: document + cursors + history as one immutable value |
| `textbuffer.document` | the line store, with transient-style `thaw`/`replace!`/`freeze` editing |
| `textbuffer.cursor` | the cursor record, ranges, and normalization (merging) |
| `textbuffer.motion` | cursor movement and the goal column |
| `textbuffer.edit` | multi-cursor edits, replacements, replaying them for undo/redo |
| `textbuffer.position` | positions packed into one `long`, ordered lexicographically |
| `textbuffer.command` | parsing and executing the CLI's command language |
| `textbuffer.cli` | the stdin/stdout program |

## Tests

```sh
clojure -M:test      # or: clojure -X:test
```

Uses `clojure.test` with the Cognitect test-runner. Besides example-based unit
tests per namespace and the worked examples of the spec run through the CLI,
`properties_test.clj` uses `test.check` to compare multi-cursor edits against a
naive offset-based model, and to check the structural invariants and the
undo/redo laws on random command sequences.
