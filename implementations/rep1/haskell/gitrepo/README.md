# gitrepo

A Haskell library and command-line tool that reads a git repository straight
off disk and answers queries about it — **without** `git`, a git library, a
zlib/DEFLATE library or a SHA-1 library. Everything below the queries is
implemented here, using only GHC's bundled packages (`base`, `bytestring`,
`containers`, `array`, `directory`, `filepath`):

| module | responsibility |
|---|---|
| `Git.SHA1` | SHA-1 (FIPS 180-4) |
| `Git.Inflate` | RFC 1950/1951 decoder that reports where a stream ends |
| `Git.Delta` | applying `OFS_DELTA` / `REF_DELTA` instruction streams |
| `Git.Pack` | pack index v2 lookup (fanout + binary search, prefix search) and packfile entry decoding |
| `Git.Object` | commits, trees, tags, stored-form parsing, object hashing |
| `Git.Store` | opening a repository; reading objects (loose first, then packs) with per-run caching |
| `Git.Ref` | `HEAD`, loose refs, `packed-refs`, symbolic refs |
| `Git.Revision` | `^`, `~`, `^{...}`, ref-name patterns, abbreviated ids, peeling |
| `Git.Quote` | git's default path quoting |
| `Git.Query` | `log`, `ls-tree`, `cat-file`, `diff`, `rev-parse`, `count-objects` |
| `Git.Command`, `Git.Batch` | the command language and the batch driver used by the CLI |
| `Git` | umbrella module re-exporting the high-level API |

## Building

Requires GHC 9.14 and cabal 3.18 (no packages beyond those bundled with GHC;
the tests also need `hspec` and `QuickCheck`).

```sh
./build.sh          # cabal build, then copies the executable to bin/gitrepo
cabal test          # runs the test suite
```

## Command-line usage

```
gitrepo <input path> <output dir>
./run.sh <input path> <output dir>      # same, from any directory
```

`<input path>` is a directory holding

* `repo/` — a git object database (the contents of a `.git` directory, or a bare repo);
* `commands.txt` — one query per line, tokens separated by single spaces.

For the command on line *k* the tool writes `<output dir>/NNN.out` (`NNN` = *k*,
zero-padded to at least three digits). A command that fails for any reason — unknown
command, wrong arity, unresolvable revision, missing or damaged object — produces
the file content `error`. The exit status is always 0.

| command | output |
|---|---|
| `rev-parse <rev>` | the 40-digit id the revision resolves to |
| `log <rev> [<n>]` | `<id> <author> <author-time> <subject>` per commit, reverse committer-date order |
| `ls-tree <rev> [<path>]` | `<mode> <type> <id>\t<quoted name>` per entry, stored order |
| `cat-file <rev>` | `<type> <size>\n` and the raw payload, after verifying its SHA-1 |
| `diff <rev1> <rev2>` | raw diff lines `:<m1> <m2> <id1> <id2> <A\|D\|M\|T>\t<path>`, sorted by path |
| `count-objects` | `loose:`, `in-pack:` and `packs:` lines |

`SPEC.md`-style details (revision syntax, quoting, tie-breaking in `log`) are
documented in the Haddock comments of the modules above.

Example `commands.txt`:

```
count-objects
rev-parse main~2
log main 5
ls-tree main src
diff v1.0 main
```

## Library usage

```haskell
{-# LANGUAGE OverloadedStrings #-}
import qualified Data.ByteString.Char8 as BC
import Control.Exception (try)
import Git

main :: IO ()
main = do
  -- Read the pack indexes, packs and loose-object list once.
  repo <- openRepository ".git"

  -- Resolve revisions; failures are thrown as 'GitError'.
  oid <- resolveRevision repo "main~2"
  BC.putStrLn (objectIdToHex oid)

  -- Objects are decoded and parsed at most once per Repository.
  commit <- readCommit repo oid
  print (identName (commitAuthor commit), commitSubject commit)

  -- The queries return exactly the bytes the CLI would write.
  history <- logHistory repo "main" (Just 5)
  BC.putStr history

  r <- try (catFile repo "no-such-ref")
  case r of
    Left (BadRevision why) -> putStrLn ("failed: " ++ why)
    Left other             -> print other
    Right out              -> BC.putStr out
```

Or run a whole command file the way the CLI does:

```haskell
runBatch "input" "output"   -- reads input/repo and input/commands.txt
```

## Design notes

* One `Repository` value answers every query of a run. Pack indexes and packs are
  read once; every reconstructed object (delta bases included) and every parsed
  commit and tree is cached; query results are not.
* Abbreviated ids resolve in O(log N) by binary search over each pack's sorted id
  table and over the sorted set of loose ids.
* `log` keeps its pending commits in an ordered map keyed by
  (committer date descending, discovery order), and reads only the commits it reaches.
* `diff` reads every tree on both sides, flattens them and merge-joins by path.
* `cat-file` always verifies the SHA-1 of header plus payload.
* The decoder checks the Adler-32 trailer, so a damaged stream is rejected where it is read.
