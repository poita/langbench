# ordered-map

A persistent ordered map from 64-bit signed integer keys to arbitrary values,
written in Clojure from scratch as a size-augmented AVL tree, plus a small
command-line tool that drives it from a line-oriented command language.

* Insert, delete, `get`, `min`, `max`, `floor`, `ceil`, `succ`, `pred`,
  `rank` and `select` are all O(log n); `size` is O(1).
* Range listing is O(log n + r) for r results.
* Neighbour queries never compute `key ± 1`, so they are safe at
  `Long/MIN_VALUE` and `Long/MAX_VALUE`.
* No dependencies beyond Clojure itself (tests use `test.check` and the
  Cognitect test-runner).

## Layout

| namespace              | responsibility                                          |
|------------------------|---------------------------------------------------------|
| `ordered-map.core`     | public API: the `OrderedMap` type and its operations    |
| `ordered-map.node`     | AVL node type, rebalancing and rotations                |
| `ordered-map.tree`     | persistent insert and delete                            |
| `ordered-map.query`    | floor/ceil/rank/select/range traversals on a tree       |
| `ordered-map.commands` | parse and execute the text command language             |
| `ordered-map.main`     | the CLI entry point (stdin → stdout)                    |

## Build

Requires Java and the `clojure` CLI (Clojure 1.12.x).

    ./build.sh      # AOT-compiles the CLI into target/classes

## Command-line usage

    ./run.sh < commands.txt

Input: a line with the number of commands `Q`, then `Q` command lines (tokens
separated by single spaces). Output: exactly one line per command.

| command                | output                                                         |
|------------------------|----------------------------------------------------------------|
| `insert <key> <value>` | `ok` if new, `updated` if the key existed (value replaced)     |
| `delete <key>`         | `ok` if removed, `missing` otherwise                           |
| `get <key>`            | the value, or `missing`                                        |
| `size`                 | number of keys                                                 |
| `min` / `max`          | smallest / largest key, or `empty`                             |
| `floor` / `ceil <key>` | largest key ≤ / smallest key ≥ `key`, or `missing`             |
| `pred` / `succ <key>`  | largest key < / smallest key > `key`, or `missing`             |
| `rank <key>`           | number of keys strictly less than `key`                        |
| `select <k>`           | the k-th smallest key (0-based), or `missing`                  |
| `range <lo> <hi>`      | keys in [lo, hi] ascending, space-separated, or `empty`        |

Example:

    $ printf '5\ninsert 5 five\ninsert 2 two\nrange 1 9\nrank 5\nselect 1\n' | ./run.sh
    ok
    ok
    2 5
    1
    5

## Library usage

Add the project to `deps.edn` (for example as a `:local/root` dependency), then:

```clojure
(require '[ordered-map.core :as om])

(def m (-> (om/ordered-map)
           (om/insert 10 "a")
           (om/insert 20 "b")
           (om/insert 30 "c")))

(om/count m)            ;=> 3
(om/get m 20)           ;=> "b"
(m 20)                  ;=> "b"          ; maps are callable
(om/floor m 25)         ;=> 20
(om/succ m 30)          ;=> nil
(om/rank m 21)          ;=> 2
(om/select m 2)         ;=> 30
(om/range-keys m 15 30) ;=> [20 30]
(om/entries (om/delete m 20)) ;=> [[10 "a"] [30 "c"]]
```

Maps are immutable: every update returns a new map sharing structure with the
old one. Queries for a key that does not exist return `nil`. See the
docstrings in `ordered-map.core` for the full API: `ordered-map`, `count`,
`contains?`, `get`, `insert`, `delete`, `min-key`, `max-key`, `floor`, `ceil`,
`succ`, `pred`, `rank`, `select`, `range-keys`, `reduce-keys`, `entries`.

## Tests

    clojure -M:test        # or: clojure -X:test

The suite contains example-based tests, structural AVL-invariant checks
(including 100 000 sorted insertions and descending deletions) and a
`test.check` property comparing the map against `clojure.core/sorted-map`.
