# orderbook

A single-instrument **limit order book matching engine** with price-time
priority, written in Haskell. It ships as a reusable library plus a thin
command-line tool that reads order commands from stdin and prints the
resulting events.

Supported commands: `LIMIT` (plain, `IOC`, `FOK`), `MARKET`, `CANCEL`,
`REPLACE` (priority-keeping and priority-losing) and `BOOK`.

## Design

* Each side of the book is an `IntMap` from price to level, so the best price
  is found (and an emptied level removed) in O(log P).
* A level is a FIFO queue stored as an `IntMap` keyed by arrival sequence
  number, with its total quantity and order count kept up to date. Orders can
  be taken out of the middle without scanning, and FOK checks and `BOOK`
  lines read level totals in O(1).
* A `Map` from order id to its location serves `CANCEL` / `REPLACE`.
* All quantities are 64-bit `Int`s.

Modules:

| Module              | Responsibility                                   |
|---------------------|--------------------------------------------------|
| `OrderBook`         | convenience re-exports and `processInput`        |
| `OrderBook.Types`   | `Command`, `Event`, `Side`, ...                  |
| `OrderBook.Book`    | persistent book structure (no matching rules)    |
| `OrderBook.Engine`  | matching: `execute`, `run`                       |
| `OrderBook.Parse`   | text → `Command`                                 |
| `OrderBook.Render`  | `Event` → text                                   |

## Build

Requires GHC 9.14.1 and cabal 3.18.2.0.

```
./build.sh          # or: cabal build exe:orderbook
cabal test          # unit tests, spec examples and property tests
```

## CLI

`./run.sh` reads the whole input on stdin and writes events to stdout:

```
$ printf '3\nLIMIT s1 SELL 101 5\nLIMIT b1 BUY 102 3\nBOOK\n' | ./run.sh
REST s1
TRADE b1 s1 101 3
FILLED b1
ASK 101 2 1
--
```

The first line is the command count `N`, followed by `N` commands:

```
LIMIT <id> <BUY|SELL> <price> <qty> [IOC|FOK]
MARKET <id> <BUY|SELL> <qty>
CANCEL <id>
REPLACE <id> <price> <qty>
BOOK
```

Output events are `TRADE`, `REST`, `CANCEL`, `REJECT`, `FILLED`, `BID`,
`ASK` and `--`; see `problems/orderbook/SPEC.md` for the exact semantics.

## Library example

```haskell
import OrderBook
import qualified Data.ByteString.Char8 as C

main :: IO ()
main = do
  let cmds = [ Limit (C.pack "s1") Sell 101 5 GoodTillCancel
             , Limit (C.pack "b1") Buy  102 3 GoodTillCancel
             , Snapshot ]
  mapM_ print (run cmds)
  -- Rest "s1"
  -- Trade "b1" "s1" 101 3
  -- Filled "b1"
  -- AskLevel 101 2 1
  -- EndOfBook
```

For incremental use, thread a book through `execute :: Command -> Book ->
([Event], Book)` starting from `emptyBook`.

## Tests

`cabal test` runs an hspec suite: parser tests, the worked examples from the
spec, targeted engine cases, and QuickCheck properties that compare the
engine against a deliberately naive list-based reference model
(`test/Reference.hs`) on random command streams.
