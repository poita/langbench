# orderbook

A single-instrument **limit order book** with price-time priority, written in
Clojure: a small library (`orderbook.core`) plus a command-line tool that reads
a stream of order commands on stdin and prints the resulting events on stdout.

Supported orders: limit (GTC), IOC, FOK, market, cancel, replace (with the
usual "keep priority only if the price is unchanged and the size not
increased" rule) and book snapshots.  Quantities are 64-bit throughout.

## Layout

| Namespace            | Responsibility                                                |
|----------------------|---------------------------------------------------------------|
| `orderbook.core`     | Public API: `new-book`, `execute!`, `limit-order!`, `snapshot`… |
| `orderbook.engine`   | Matching: price-time priority, FOK check, cancel, replace     |
| `orderbook.book`     | Mutable book structures (sorted price levels, FIFO queues)    |
| `orderbook.event`    | Event constructors and their text rendering                   |
| `orderbook.command`  | Command maps and the text-protocol parser                     |
| `orderbook.stream`   | The stdin/stdout protocol (count header, one command per line)|
| `orderbook.cli`      | `-main`, a thin wrapper over `orderbook.stream`               |

### Design

Each side is a `java.util.TreeMap` from price to level, ordered best-first, so
the best level is found and an emptied level removed in O(log P).  A level is a
`LinkedHashMap` (a FIFO queue with O(1) removal from the middle) plus a running
quantity total and order count, so FOK checks and `BOOK` lines read a level in
O(1).  A `HashMap` from id to order serves `CANCEL` and `REPLACE`.

## Build

Requires Java and the Clojure CLI (`clojure`); developed with Clojure 1.12.6 on
Java 27.

    ./build.sh      # AOT-compiles the CLI into target/classes and records the classpath

## Command-line use

    ./run.sh < commands.txt > events.txt

Input: a count `N`, then `N` command lines:

    LIMIT <id> <BUY|SELL> <price> <qty> [IOC|FOK]
    MARKET <id> <BUY|SELL> <qty>
    CANCEL <id>
    REPLACE <id> <price> <qty>
    BOOK

Output: one event per line (`TRADE`, `REST`, `CANCEL`, `REJECT`, `FILLED`,
`BID`, `ASK`, `--`).  The exact formats and semantics are in `SPEC.md` of the
problem statement.  Example:

    $ printf '3\nLIMIT s1 SELL 101 5\nLIMIT b1 BUY 101 3\nBOOK\n' | ./run.sh
    REST s1
    TRADE b1 s1 101 3
    FILLED b1
    ASK 101 2 1
    --

Without building, `clojure -M:cli < commands.txt` does the same.

## Library use

```clojure
(require '[orderbook.core :as ob])

(def book (ob/new-book))

(ob/limit-order! book "s1" :sell 101 5)
;; => [{:event :rest, :id "s1"}]

(ob/limit-order! book "b1" :buy 101 3)
;; => [{:event :trade, :taker "b1", :maker "s1", :price 101, :qty 3}
;;     {:event :filled, :id "b1"}]

(ob/limit-order! book "b2" :buy 100 10 :tif :ioc)   ; :gtc (default) | :ioc | :fok
(ob/market-order! book "m1" :buy 1)
(ob/replace-order! book "s1" 102 4)                 ; loses priority: price changed
(ob/cancel-order! book "s1")

(ob/snapshot book)
;; => {:bids [] :asks []}   ; vectors of {:price :qty :orders}, best first

(map ob/format-event (ob/execute! book {:op :book}))
```

Every operation returns a vector of event maps (see `orderbook.event`);
`execute!` also accepts a sink function to receive events without collecting
them.  A book is mutable and not thread-safe.

## Tests

    clojure -X:test

Uses `clojure.test` with the Cognitect test-runner.  Besides example-based
tests (the worked examples of the spec, parser, formatter, stream protocol)
there is a `test.check` property test comparing the engine with a naive
reference model on random command sequences.
