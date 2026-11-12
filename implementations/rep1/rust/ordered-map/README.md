# ordered-map

An ordered map from 64-bit signed integer keys to values, written from scratch
as an **AVL tree augmented with subtree sizes**. It supports insertion,
deletion, lookup, order statistics (`rank`, `select`), neighbour queries
(`floor`, `ceil`, `succ`, `pred`) and inclusive range listing. Everything is
`O(log n)` except range listing, which is `O(log n + r)` for `r` keys reported.

The project is a reusable library (`ordered_map`) plus a thin command-line tool
(`ordered-map`) that executes a script of commands. It depends only on the Rust
standard library.

## Layout

| path             | responsibility                                          |
|------------------|---------------------------------------------------------|
| `src/map.rs`     | `OrderedMap`: arena-backed AVL tree, queries, updates   |
| `src/iter.rs`    | `Range` / `Iter` / `Keys` iterators (pruned in-order walk) |
| `src/command.rs` | `Command` enum and its line parser (`FromStr`)          |
| `src/exec.rs`    | executing commands and rendering output lines           |
| `src/main.rs`    | the CLI: stdin → stdout                                 |
| `tests/`         | integration tests (public API, CLI binary)              |

## Build

```
./build.sh            # or: cargo build --release
```

The binary is `target/release/ordered-map`; `./run.sh` runs it from any
directory.

## Command-line usage

```
./run.sh < commands.txt
```

Input: a first line `Q`, then `Q` command lines (single-space separated):

| command                | output                                                  |
|------------------------|---------------------------------------------------------|
| `insert <key> <value>` | `ok` (new key) or `updated` (value replaced)            |
| `delete <key>`         | `ok` or `missing`                                       |
| `get <key>`            | the value, or `missing`                                 |
| `size`                 | number of keys                                          |
| `min` / `max`          | smallest / largest key, or `empty`                      |
| `floor` / `ceil <key>` | largest key ≤ / smallest key ≥ `key`, or `missing`      |
| `succ` / `pred <key>`  | smallest key > / largest key < `key`, or `missing`      |
| `rank <key>`           | number of keys strictly less than `key`                 |
| `select <k>`           | the k-th smallest key (0-based), or `missing`           |
| `range <lo> <hi>`      | keys in `[lo, hi]` ascending on one line, or `empty`    |

Keys are `i64`; values are 1–32 printable ASCII characters without spaces and
are stored verbatim. Example:

```
$ printf '5\ninsert 5 five\ninsert 2 two\nrange 1 9\nrank 5\nselect 1\n' | ./run.sh
ok
ok
2 5
1
5
```

Malformed input makes the tool print a diagnostic to stderr and exit non-zero.

## Library usage

```rust
use ordered_map::OrderedMap;

let mut m = OrderedMap::new();
m.insert(10, "a");
m.insert(20, "b");
m.insert(30, "c");

assert_eq!(m.insert(20, "B"), Some("b"));   // replaced
assert_eq!(m.floor(25), Some(20));
assert_eq!(m.successor(i64::MAX), None);    // no overflow at the extremes
assert_eq!(m.rank(21), 2);
assert_eq!(m.select(0), Some(10));
let in_range: Vec<i64> = m.range(15..=30).map(|(k, _)| k).collect();
assert_eq!(in_range, [20, 30]);
assert_eq!(m.remove(10), Some("a"));
```

## Tests

```
cargo test
```

Unit tests cover the tree (including a randomised comparison against
`std::collections::BTreeMap` with invariant checks — the standard map is used
only as a test oracle), the parser and the executor; integration tests cover
the public API and the CLI binary.

## Design notes

* Nodes live in a `Vec` arena addressed by `u32` indices, with a free list
  for reuse, so there is no per-node allocation.
* Each node caches its height and subtree size; rotations and rebalancing
  maintain both, so `rank`/`select` walk a single root-to-node path.
* `succ`/`pred` are strict-comparison searches rather than `key ± 1`, so
  `i64::MIN`/`i64::MAX` cannot overflow.
* `range` is a lazy iterator with an explicit stack: it descends to the first
  key ≥ `lo`, then yields in order until a key exceeds `hi`.
