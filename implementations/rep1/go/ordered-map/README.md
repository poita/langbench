# ordered-map

An ordered map from 64-bit signed integer keys to short string values, written
in Go with only the standard library. The tree is a hand-written AVL tree
augmented with subtree sizes, so insert, delete, lookup, neighbour queries,
`rank` and `select` are all O(log n), and listing a range is O(log n + r).

The repository has three parts:

| path | what |
|------|------|
| `orderedmap/` | the reusable library (`Map`): `map.go` (node pool, insert, delete, rebalancing), `query.go` (lookups, neighbours, rank/select, range traversal), `check.go` (invariant checker for tests) |
| `script/` | parser/executor for the line-oriented command language, built on the library |
| `cmd/ordered-map/` | thin CLI: stdin → stdout |

Nodes live in one index-addressed pool (index 0 is a nil sentinel, freed slots
are reused), and values are kept as references to the caller's bytes, not
copied.

## Build

Requires Go 1.27 or newer.

```sh
./build.sh          # produces bin/ordered-map
go test ./...       # unit tests
```

## CLI

`./run.sh` reads a script on stdin and writes one output line per command:

```
$ printf '5\ninsert 5 five\ninsert 2 two\nrange 1 9\nrank 5\nsucc 5\n' | ./run.sh
ok
ok
2 5
1
missing
```

The first line is the command count `Q`; then `Q` commands, one per line,
tokens separated by a single space. Keys are int64 decimals (both extremes are
handled), values are 1–32 printable ASCII characters without spaces.

| command | output |
|---|---|
| `insert <key> <value>` | `ok` (new) or `updated` (replaced) |
| `delete <key>` | `ok` or `missing` |
| `get <key>` | the value or `missing` |
| `size` | number of keys |
| `min` / `max` | smallest / largest key, or `empty` |
| `floor` / `ceil <key>` | largest key ≤ / smallest key ≥ `key`, or `missing` |
| `pred` / `succ <key>` | largest key < / smallest key > `key`, or `missing` |
| `rank <key>` | number of keys strictly less than `key` |
| `select <k>` | k-th smallest key (0-based) or `missing` |
| `range <lo> <hi>` | keys in `[lo, hi]` ascending, space-separated, or `empty` |

## Library example

```go
package main

import (
	"fmt"

	"github.com/example/ordered-map/orderedmap"
)

func main() {
	m := orderedmap.New(0)
	m.Put(10, []byte("a"))
	m.Put(20, []byte("b"))
	m.Put(30, []byte("c"))

	k, _ := m.Floor(25)    // 20
	r := m.Rank(21)        // 2
	s, _ := m.Select(2)    // 30
	fmt.Println(k, r, s)

	m.Ascend(15, 40, func(key int64, val []byte) bool {
		fmt.Println(key, string(val))
		return true // return false to stop early
	})
}
```

Values passed to `Put` are retained, not copied; don't modify them afterwards.
A `Map` is not safe for concurrent use.
