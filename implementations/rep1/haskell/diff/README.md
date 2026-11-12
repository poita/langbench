# diff — Myers diff and patch in Haskell

A small library and command-line tool for line-oriented diffing and patching.

* **Exact**: `diff` always returns a *shortest* edit script (cost
  `N + M - 2·LCS`); no heuristics, cost cut-offs, or anchoring on unique lines.
* **Fast**: Eugene Myers' O((N+M)·D) greedy algorithm in its linear-space
  "middle snake" form (Myers 1986, §4b): O(N+M) memory, O(log D) recursion
  depth, common prefix/suffix trimming, and O(1) element comparison through
  interning to integer ids.
* **Standard library only** (`base`, `array`, `bytestring`, `containers`);
  `hspec` and `QuickCheck` for the tests.

## Layout

| Module           | Responsibility                                            |
|------------------|-----------------------------------------------------------|
| `Diff`           | Public entry point: `diff`, `diffBy`, `patch`, `Edit`     |
| `Diff.Types`     | `Edit` (`Keep` / `Delete` / `Insert`) and script costs    |
| `Diff.Intern`    | Interning elements to dense `Int` ids                     |
| `Diff.Myers`     | The linear-space Myers algorithm on `UArray Int Int`      |
| `Diff.Patch`     | Applying an edit script (checked and unchecked)           |
| `Diff.Script`    | Textual script format (` `, `-`, `+` tagged lines)        |
| `Diff.Protocol`  | The stdin/stdout protocol used by the CLI                 |
| `app/Main.hs`    | Thin CLI wrapper around `Diff.Protocol`                   |

## Build

Requires GHC 9.14.1 and cabal 3.18.2.0.

```sh
./build.sh          # cabal build, copies the binary to bin/diff-cli
cabal test          # runs the hspec/QuickCheck suite
```

## Command-line use

`./run.sh` (or `bin/diff-cli`) reads a request on stdin and writes the answer on
stdout. The first line is the mode, `diff` or `patch`; every block of lines is
preceded by its count, and content is read strictly by those counts.

```
diff            patch
N               N
<N lines of A>  <N lines of A>
M               K
<M lines of B>  <K script lines>
```

A script line is a one-character tag followed by the line's content: a space
keeps the next line of A, `-` deletes it, `+` inserts the given line.

* `diff` prints `K` and then a minimal script of `K` lines turning A into B.
* `patch` prints `M` and then the `M` lines of the patched file.

Whitespace in content is significant (lines are compared byte for byte). A
malformed request prints a message on stderr and exits with status 1.

```console
$ printf 'diff\n3\na\nb\nc\n3\na\nB\nc\n' | ./run.sh
4
 a
-b
+B
 c
```

## Library use

```haskell
import Diff

main :: IO ()
main = do
  let old = lines "one\ntwo\nthree\n"
      new = lines "one\n2\nthree\nfour\n"
      script = diff old new
  mapM_ print script
  -- Keep "one" / Delete "two" / Insert "2" / Keep "three" / Insert "four"
  print (scriptCost script)      -- 3
  print (patch old script == Right new)   -- True
```

* `diff :: Ord a => [a] -> [a] -> [Edit a]` — shortest script.
* `diffBy :: Ord k => (a -> k) -> [a] -> [a] -> [Edit a]` — compare via a key.
* `patch :: Eq a => [a] -> [Edit a] -> Either PatchError [a]` — validating
  patch; `Diff.Patch.patchUnchecked` skips validation.
* `Diff.Myers.diffIds` works directly on interned `UArray Int Int` sequences and
  returns index-based edits.
* `Diff.Script` / `Diff.Protocol` render and parse the text formats.
