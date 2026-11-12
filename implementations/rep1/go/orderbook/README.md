# orderbook

A single-instrument **limit order book matching engine** with price-time
priority, written in Go. It consists of

- a reusable library (`github.com/peteralexander/orderbook`) with limit, IOC,
  FOK, market, cancel and replace semantics;
- a `protocol` package that parses the text command format and prints events;
- a thin command-line tool, `orderbook`, that reads commands on stdin and
  writes events to stdout.

It uses only the Go standard library (tests use the standard `testing`
package).

## Layout

| Path                 | Responsibility                                                    |
|----------------------|-------------------------------------------------------------------|
| `types.go`           | public types: `Side`, `TimeInForce`, `Command`, `Event`, `Level`  |
| `book.go`            | `Book`: command processing, matching, snapshots                   |
| `side.go`            | one side of the book: price levels, best level, add/remove        |
| `level.go`           | price level and resting order: intrusive FIFO queue, totals       |
| `tree.go`            | treap over price levels                                           |
| `protocol/`          | command parser, event formatter, `Run` loop                       |
| `cmd/orderbook/`     | the CLI                                                           |

## Build

Requires Go 1.27 or newer.

```sh
./build.sh          # produces bin/orderbook (runs: go build -o bin/orderbook ./cmd/orderbook)
./run.sh < in.txt   # runs the built binary
go test ./...       # runs the tests
```

## Command-line usage

```sh
orderbook < commands.txt > events.txt
```

Input: a line with the command count `N`, then `N` command lines, tokens
separated by single spaces:

```
LIMIT <id> <side> <price> <qty> [IOC|FOK]
MARKET <id> <side> <qty>
CANCEL <id>
REPLACE <id> <price> <qty>
BOOK
```

Output: one event per line:

```
TRADE <taker-id> <maker-id> <price> <qty>
REST <id>
CANCEL <id> <remaining-qty>
REJECT <id>
FILLED <id>
BID <price> <total-qty> <n-orders>     (BOOK only)
ASK <price> <total-qty> <n-orders>     (BOOK only)
--                                     (end of BOOK)
```

Example:

```sh
$ printf '4\nLIMIT s1 SELL 101 5\nLIMIT b1 BUY 102 8\nBOOK\nCANCEL b1\n' | ./run.sh
REST s1
TRADE b1 s1 101 5
FILLED s1
REST b1
BID 102 3 1
--
CANCEL b1 3
```

Trades execute at the resting (maker) order's price. `REPLACE` sets the new
*remaining* quantity; an unchanged price with a non-increased quantity keeps
queue priority, anything else re-enters the order as a fresh limit order. The
exit code is 0 on success, 1 on malformed input or I/O errors, 2 on bad usage.

## Library example

```go
package main

import (
	"fmt"

	"github.com/peteralexander/orderbook"
)

func main() {
	book := orderbook.New()
	book.Limit("s1", orderbook.Sell, 101, 5, orderbook.GTC)

	// Each call returns the events it produced; the slice is only valid until
	// the next call on the same book.
	for _, e := range book.Limit("b1", orderbook.Buy, 102, 8, orderbook.GTC) {
		fmt.Println(e) // TRADE b1 s1 101 5 / FILLED s1 / REST b1
	}

	fmt.Println(book.Bids()) // [{102 3 1}]
	book.Replace("b1", 102, 2)
	book.Cancel("b1")
}
```

The `protocol` package drives a book from text:

```go
err := protocol.Run(os.Stdin, os.Stdout)
```

## Design

Each side of the book keeps its price levels in a treap keyed by price, a hash
map from price to level, and a pointer to the best level. A level holds an
intrusive doubly linked FIFO queue of orders with a running total quantity and
order count; a hash map from id to order serves `CANCEL` and `REPLACE`.

- best price: O(1); removal of an emptied level: O(log P);
- cancel / priority-losing replace: O(1) queue removal, O(log P) if the level
  empties;
- FOK check: O(levels crossed) using the maintained level totals;
- `BOOK`: O(k) for k levels printed.

All quantities and sums are `uint64`.
