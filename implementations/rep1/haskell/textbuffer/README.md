# textbuffer

The editing core of a text editor, as a Haskell library plus a small
command-line driver: a document made of lines, a set of cursors (each
optionally holding a selection), insertion and deletion at every cursor,
cursor movement with a remembered goal column, and undo/redo.

Only GHC's bundled packages are used (`base`, `bytestring`, `containers`);
the tests additionally use `hspec` and `QuickCheck`.

## Build

Requires GHC 9.14 and cabal 3.18.

```sh
./build.sh                 # cabal build, then copies the binary to bin/textbuffer
cabal build               # library + executable
cabal test                # unit, golden and property tests
```

## Command-line tool

`./run.sh` (or `bin/textbuffer`) reads a script on stdin and writes the result
of each `print` command to stdout.

Input: a line with the number `N` of document lines, those `N` lines verbatim,
then one command per line:

| command | effect |
|---|---|
| `insert <text>` | insert at every cursor, replacing selections (`\n` = newline, `\\` = backslash) |
| `delete` / `delete-forward` | backspace / delete; removes the selections if any |
| `move left\|right\|up\|down\|home\|end [select]` | move every cursor, optionally extending selections |
| `goto <line> <col>` | a single cursor at the (clamped) position |
| `add-cursor <line> <col>` | add a cursor |
| `clear-cursors` | keep only the primary cursor |
| `undo` / `redo` | one step is one edit command |
| `print` | write the document, a `cursor <line> <col>` line per cursor, then `--` |

```console
$ printf '2\nhello world\nsecond line\nmove end\ninsert !\nmove down\nprint\n' | ./run.sh
hello world!
second line
cursor 1 11
--
```

Malformed input is reported on stderr with a non-zero exit status.

## Library

The `TextBuffer` module is the public API; the modules below it are exposed
too, split by responsibility:

| module | contents |
|---|---|
| `TextBuffer.Position` | `Pos`, position arithmetic |
| `TextBuffer.Document` | the line sequence: `slice`, `replace`, clamping |
| `TextBuffer.Cursor` | `Cursor`, ranges, normalization (merging colliding cursors) |
| `TextBuffer.Movement` | moving one cursor |
| `TextBuffer.Command` | the `Command` type and its parser |
| `TextBuffer.Buffer` | `Buffer`: document + cursors + undo/redo; `execute`, `undo`, `redo`, `render` |
| `TextBuffer.Script` | parsing and running a whole script |

A `Buffer` is an immutable value; every operation returns a new one.

```haskell
import qualified Data.ByteString.Char8 as B
import TextBuffer
import qualified TextBuffer.Document as Doc

main :: IO ()
main = do
  let buffer0 = fromLines [B.pack "alpha", B.pack "beta"]
      script  = ["add-cursor 1 0", "insert - ", "move end select", "insert X"]
      Right commands = mapM (parseCommand . B.pack) script
      buffer1 = foldl (flip execute) buffer0 commands
  mapM_ (putStrLn . B.unpack) (Doc.toLines (document buffer1))  -- "- X" / "- X"
  print (map curHead (cursors buffer1))                           -- [Pos 0 3,Pos 1 3]
  print (map B.unpack (Doc.toLines (document (undo buffer1))))
```

## Design

* The document is a `Data.Sequence` of strict `ByteString` lines; a replacement
  costs O(ℓ + m) for the edited line plus O(log L) for the sequence.
* A multi-cursor edit visits the cursors once, in order; each later cursor is
  mapped through the composed effect of the earlier replacements in O(1)
  (a single "original position → new position" shift).
* Normalization is a stable sort plus one merge sweep.
* An undo entry holds the cursors before and after, and the list of
  replacements `(start, removed, inserted)`; never a copy of the document.

Known limit: many cursors on one very long line cost O(ℓ) *each* (every
replacement copies the line), e.g. 2 000 cursors on a 3 000 000-character line
take about 0.1 s per edit.
