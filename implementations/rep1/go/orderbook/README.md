# orderbook

A single-instrument limit order book matching engine with price-time priority,
written in Go using only the standard library. It consists of a reusable
library (package `orderbook`) and a thin command-line tool that reads a stream
of order commands on stdin and prints the resulting events on stdout.

Supported: limit orders (plain, IOC, FOK), market orders, cancel, replace
(with the rule that only a price-preserving, non-increasing quantity change keeps
queue priority) and book listings. Quantities are 64-bit throughout.

## Build

Requires Go 1.27.1 or newer.

```sh
./build.sh          # builds bin/orderbook (works from any directory)
go test ./...       # unit tests
```

## Command-line use

```sh
./run.sh < commands.txt
```

Input: a line with the command count `N`, then `N` lines, one per command
(tokens separated by single spaces; the last newline is optional):

```
LIMIT <id> <BUY|SELL> <price> <qty> [IOC|FOK]
MARKET <id> <BUY|SELL> <qty>
CANCEL <id>
REPLACE <id> <price> <qty>
BOOK
```

Output: one event per line — `TRADE <taker> <maker> <price> <qty>`,
`REST <id>`, `CANCEL <id> <remaining>`, `REJECT <id>`, `FILLED <id>`, and for
`BOOK` the lines `BID|ASK <price> <total-qty> <n-orders>` followed by `--`.
Malformed input makes the tool print a message to stderr and exit with
status 1.

```console
$ printf '3\nLIMIT a BUY 100 5\nLIMIT b SELL 99 8 IOC\nBOOK\n' | ./run.sh
REST a
TRADE b a 100 5
FILLED a
CANCEL b 3
--
```

## Library use

```go
package main

import (
	"fmt"

	"github.com/example/orderbook"
)

func main() {
	// A book accepts a fixed, ascending table of prices.
	book, err := orderbook.NewBook([]int64{99, 100, 101})
	if err != nil {
		panic(err)
	}
	book.Limit([]byte("s1"), orderbook.Sell, 101, 5, orderbook.GTC)
	book.Limit([]byte("b1"), orderbook.Buy, 101, 8, orderbook.GTC) // trades 5, rests 3
	book.Snapshot()
	fmt.Print(string(book.Output()))

	book.EachLevel(orderbook.Buy, func(l orderbook.Level) bool {
		fmt.Println(l.Price, l.Qty, l.Orders)
		return true
	})
}
```

To process a whole text stream instead, use `orderbook.Run(input)`, or
`orderbook.Parse` followed by `(*Script).Run`.

## Layout

| File | Responsibility |
| --- | --- |
| `types.go` | public types: `Side`, `TimeInForce`, `Command`, `Level`, errors |
| `book.go` | the `Book`: levels, order arena, FIFO links, matching, cancel/replace, book listing |
| `segtree.go` | segment tree over price levels: best level, range sums, next/previous non-empty level |
| `parse.go` | hand-written parser; collects and ranks the price table |
| `run.go` | `Run` / `Script.Run` convenience entry points |
| `cmd/orderbook` | the command-line tool |

## How it works

Prices are collected from the whole input first, sorted and ranked, so each
side of the book is a dense array of levels indexed by rank. A segment tree per
side (quantity sum + non-empty count) finds the best level, answers the
fill-or-kill liquidity check as one range sum, and walks the non-empty levels
for `BOOK`, all in O(log P). Orders live in an arena with intrusive doubly
linked FIFO queues per level, so fills at the head and cancels from the
middle are O(1); one hash map from id to arena index serves cancel and
replace.

`Book` methods take prices from its fixed table (`ErrUnknownPrice` otherwise)
and require ids not to collide with currently resting orders. A `Book` is not
safe for concurrent use.
