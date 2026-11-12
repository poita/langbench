# ordered-map

A balanced ordered map written from scratch in Haskell: an AVL tree augmented
with subtree sizes, keyed by any `Ord` type. It supports insertion, deletion,
lookup, order statistics (`rank`, `select`), neighbour queries (floor, ceiling,
successor, predecessor) and inclusive range listing. The package also ships a
small command-line tool that runs a script of map commands.

No ordered-map, set or balanced-tree library is used; the only dependencies
are `base` and `bytestring` (plus `hspec` and `QuickCheck` for the tests).

## Complexity

| operation                                        | cost            |
|--------------------------------------------------|-----------------|
| `insert`, `delete`, `lookup`, `lookupMin/Max`    | O(log n)        |
| `lookupFloor/Ceil/Succ/Pred`                     | O(log n)        |
| `rank`, `select` (use cached subtree sizes)      | O(log n)        |
| `size`, `null`                                   | O(1)            |
| `range lo hi` (pruned in-order walk, `r` results)| O(log n + r)    |

## Layout

| module                      | responsibility                                          |
|-----------------------------|---------------------------------------------------------|
| `Data.OrderedMap`           | public API: queries, order statistics, ranges           |
| `Data.OrderedMap.Internal`  | AVL representation, rotations, insert/delete, `valid`   |
| `OrderedMap.Command`        | command type and line parser for the CLI language       |
| `OrderedMap.Interpreter`    | executes commands against a map, renders output         |
| `app/Main.hs`               | thin stdin/stdout wrapper                               |

## Build

Requires GHC 9.14.1 and cabal 3.18.2.0.

```sh
./build.sh          # cabal build, and copies the binary to bin/ordered-map
cabal test          # run the hspec/QuickCheck test suite
```

## Command-line tool

```sh
./run.sh < script.txt
```

Input: line 1 is `Q`, the number of commands, followed by `Q` command lines
(tokens separated by single spaces). Output: exactly one line per command.
Keys are 64-bit signed decimal integers; values are 1–32 printable ASCII
characters without spaces and are echoed back verbatim.

| command                | output                                                                  |
|------------------------|-------------------------------------------------------------------------|
| `insert <key> <value>` | `ok` if new, `updated` if the key existed (value replaced)              |
| `delete <key>`         | `ok` if removed, `missing` otherwise                                    |
| `get <key>`            | the value, or `missing`                                                 |
| `size`                 | number of keys                                                          |
| `min` / `max`          | smallest / largest key, or `empty`                                      |
| `floor` / `ceil <key>` | largest key ≤ / smallest key ≥ `key`, or `missing`                      |
| `succ` / `pred <key>`  | smallest key > / largest key < `key`, or `missing`                      |
| `rank <key>`           | number of keys strictly less than `key`                                 |
| `select <k>`           | the k-th smallest key (0-based), or `missing`                           |
| `range <lo> <hi>`      | keys in `[lo, hi]` ascending, space separated, or `empty`               |

Example:

```console
$ printf '5\ninsert 10 a\ninsert 20 b\nfloor 25\nrank 20\nrange 0 100\n' | ./run.sh
ok
ok
20
1
10 20
```

A malformed script makes the tool print a message on stderr and exit with
status 1 without writing any output.

## Library example

```haskell
import qualified Data.OrderedMap as OM

main :: IO ()
main = do
  let m = OM.fromList [(10, "a"), (20, "b"), (30, "c")]
  print (OM.lookupFloor 25 m)     -- Just (20,"b")
  print (OM.lookupSucc 30 m)      -- Nothing
  print (OM.rank 21 m)            -- 2
  print (OM.select 0 m)           -- Just (10,"a")
  print (OM.rangeKeys 15 30 m)    -- [20,30]
  let (old, m') = OM.insertLookup 20 "B" m
  print (old, OM.lookup 20 m')    -- (Just "b",Just "B")
```

Neighbour queries only compare keys (they never compute `k + 1`), so they are
correct at `minBound` / `maxBound`.

## Tests

`cabal test` runs hspec specifications for each module, including QuickCheck
properties comparing the map against a sorted-list model after random
insert/delete sequences, with AVL invariant checks (`Data.OrderedMap.Internal.valid`)
and balance checks on 100 000-key sorted insertions and deletions.
