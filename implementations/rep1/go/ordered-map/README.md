# ordered-map

A small Go library implementing an ordered map from `int64` keys to `string`
values, plus a command-line tool that drives it from a text script.

The map is a hand-written AVL tree whose nodes carry subtree sizes, so every
operation is O(log n) — including order statistics (`Rank`, `Select`) — and
`Range` is O(log n + r). Only the standard library is used.

## Layout

| path                    | contents                                                       |
|-------------------------|----------------------------------------------------------------|
| `node.go`               | AVL node, cached height/size, rotations, rebalancing           |
| `map.go`                | `Map` type: `Put`, `Delete`, `Get`, `Len`                      |
| `query.go`              | `Min`, `Max`, `Floor`, `Ceil`, `Successor`, `Predecessor`, `Rank`, `Select` |
| `range.go`              | `Range`, `Ascend` (pruned in-order traversal)                  |
| `internal/cli`          | the command protocol (parse, execute, format)                  |
| `cmd/ordered-map`       | the `main` package, a thin wrapper over `internal/cli`         |

## Build

```
./build.sh          # produces bin/ordered-map (runs `go build`)
go test ./...       # run the tests
```

Requires Go 1.27 or newer.

## Command-line usage

`./run.sh` reads a script on stdin and writes one output line per command to
stdout. The first line is the number of commands `Q`; then `Q` commands follow:

```
insert <key> <value>   ok | updated
delete <key>           ok | missing
get <key>              the value | missing
size                   number of keys
min | max              the key | empty
floor|ceil|succ|pred <key>   the key | missing
rank <key>             number of keys strictly less than <key>
select <k>             k-th smallest key (0-based) | missing
range <lo> <hi>        keys in [lo, hi], space-separated | empty
```

Keys are 64-bit signed decimals; values are 1–32 printable ASCII characters
without spaces.

```
$ printf '5\ninsert 10 a\ninsert 20 b\nfloor 25\nrank 20\nrange 0 100\n' | ./run.sh
ok
ok
20
1
10 20
```

## Library example

```go
package main

import (
	"fmt"

	orderedmap "example.com/orderedmap"
)

func main() {
	m := orderedmap.New()
	m.Put(10, "a")
	m.Put(20, "b")
	m.Put(30, "c")

	floor, _ := m.Floor(25)      // 20
	rank := m.Rank(21)           // 2
	third, _ := m.Select(2)      // 30
	fmt.Println(floor, rank, third)

	m.Range(10, 20, func(k int64, v string) bool {
		fmt.Println(k, v)
		return true // return false to stop early
	})
}
```

A `Map` is not safe for concurrent use without external locking.
