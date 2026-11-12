# orderbook

A single-instrument limit order book matching engine with price-time priority,
written in D. It is a small library (`orderbook`) plus a command-line tool that
reads order commands on stdin and prints the resulting events on stdout.

Supported orders: limit (rest / `IOC` / `FOK`), market, cancel, replace
(priority-preserving when only the quantity decreases), and a `BOOK` snapshot.
All quantities and sums are 64-bit.

## Design

* Orders sit in one pooled array and are linked into per-price FIFO queues by
  index, so cancelling or re-pricing from the middle of a queue is O(1).
* Each side keeps its price levels in a red-black tree (best price first), so
  finding the best level and removing an emptied one is O(log P).
* Every level stores its total quantity and order count, so FOK checks and
  `BOOK` lines never sum orders.
* A hash map from id to order serves `CANCEL` and `REPLACE`.

## Build

Requires LDC and dub (tested with LDC 1.41.0, dub 1.40.0):

```
./build.sh          # dub build -b release --compiler=ldc2 --config=cli  ->  bin/orderbook
dub test --compiler=ldc2
```

## Command-line tool

```
./run.sh < commands.txt
```

Input: a first line `N`, then `N` command lines:

```
LIMIT <id> <BUY|SELL> <price> <qty> [IOC|FOK]
MARKET <id> <BUY|SELL> <qty>
CANCEL <id>
REPLACE <id> <price> <qty>
BOOK
```

Output: one event per line (`TRADE`, `REST`, `CANCEL`, `REJECT`, `FILLED`,
`BID`, `ASK`, `--`); the exact format and semantics are defined in the problem
specification. Exit status is 0, or 1 (with a message on stderr) if the input
is malformed.

```
$ printf '4\nLIMIT s1 SELL 101 5\nLIMIT b1 BUY 102 8\nBOOK\nCANCEL b1\n' | ./run.sh
REST s1
TRADE b1 s1 101 5
FILLED s1
REST b1
BID 102 3 1
--
CANCEL b1 3
```

## Library

Modules (`import orderbook;` imports all of them):

| module              | contents                                                     |
|---------------------|--------------------------------------------------------------|
| `orderbook.types`   | `Side`, `TimeInForce`, `Price`, `Qty`, `Event`, `EventKind`  |
| `orderbook.book`    | `OrderBook`: `limit`, `market`, `cancel`, `replace`, `snapshot` |
| `orderbook.command` | `parseCommand`, `execute`, `processStream` (text protocol)   |
| `orderbook.format`  | `writeEvent`, `formatEvent`, `BufferedWriter`, `TextSink`    |

Every `OrderBook` operation reports its results by calling `put(Event)` on an
output range you pass in. Ids are `string`s the book keeps while an order
rests, so pass immutable data.

```d
import std.array : appender;
import std.stdio : writeln;
import orderbook;

void main()
{
    auto book = new OrderBook;
    auto events = appender!(Event[]);

    book.limit("ask1", Side.sell, 101, 5, TimeInForce.gtc, events);
    book.limit("bid1", Side.buy, 102, 8, TimeInForce.gtc, events);
    book.snapshot(events);

    foreach (e; events[])
        writeln(e);   // REST ask1 / TRADE bid1 ask1 101 5 / FILLED ask1 / REST bid1 / BID 102 3 1 / --
}
```

To depend on it from another dub project:

```
dependency "orderbook" path="../orderbook"
```

## Tests

`dub test --compiler=ldc2` runs the standard D `unittest` blocks: per-module
unit tests, the worked examples of the specification (`tests/examples.d`), and
a differential test against a naive reference implementation on random command
streams (`tests/model.d`).
