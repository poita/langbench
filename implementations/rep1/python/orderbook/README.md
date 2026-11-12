# orderbook

A single-instrument **limit order book matching engine** with price-time
priority, written in pure Python (standard library only). It ships as a
reusable library plus a thin command-line tool that reads a stream of order
commands and prints the resulting events.

Supported commands: `LIMIT` (plain, `IOC`, `FOK`), `MARKET`, `CANCEL`,
`REPLACE` (priority kept only when the price is unchanged and the quantity
does not grow) and `BOOK`.

## Layout

```
src/orderbook/
  events.py    Side and event types (Trade, Rest, Cancelled, ...) rendering as wire lines
  commands.py  command types and parse_command()
  book.py      OrderBook: per-price FIFO levels, sorted price index, matching
  engine.py    stream helpers: parse_stream(), process(), run()
  cli.py       the command-line entry point
tests/         pytest suite (unit, CLI, and randomized tests vs. a naive oracle)
build.sh run.sh
```

## Build

Requires Python 3.12+ (developed on 3.14). There are no dependencies.

```
./build.sh          # byte-compiles the sources
```

There is no install step: `run.sh` runs the package with `PYTHONPATH` pointing
at `src/`. A regular `pip install .` also works (setuptools, `pyproject.toml`).

## Command-line use

```
./run.sh < commands.txt > events.txt
```

Input: first line `N`, then `N` command lines. Output: one event line per
event, in command order. The exact formats are:

```
LIMIT <id> <BUY|SELL> <price> <qty> [IOC|FOK]
MARKET <id> <BUY|SELL> <qty>
CANCEL <id>
REPLACE <id> <price> <qty>
BOOK
```

```
$ printf '3\nLIMIT s1 SELL 101 5\nLIMIT b1 BUY 102 3\nBOOK\n' | ./run.sh
REST s1
TRADE b1 s1 101 3
FILLED b1
ASK 101 2 1
--
```

Events: `TRADE taker maker price qty`, `REST id`, `CANCEL id remaining`,
`REJECT id`, `FILLED id`, and `BID`/`ASK price total orders` lines ended by
`--` for `BOOK`.

## Library use

```python
from orderbook import OrderBook, Side, TimeInForce

book = OrderBook()
book.limit("s1", Side.SELL, 101, 5)              # [Rest(id='s1')]
events = book.limit("b1", Side.BUY, 102, 8, TimeInForce.IOC)
print([str(e) for e in events])
# ['TRADE b1 s1 101 5', 'FILLED s1', 'CANCEL b1 3']

book.limit("b2", Side.BUY, 100, 10)
book.replace("b2", 100, 4)                       # keeps queue priority -> [Rest('b2')]
print(book.snapshot())                           # [BookLevel(side=BUY, price=100, qty=4, orders=1)]
book.cancel("b2")                                # [Cancelled(id='b2', qty=4)]
```

`OrderBook` methods (`limit`, `market`, `cancel`, `replace`, `execute`) return
lists of event objects; `str(event)` is the wire-format line. Whole text
streams can be processed with `orderbook.run(text)` or
`orderbook.process(lines)`.

## Design notes

* Each side is a `price -> level` dict plus a sorted list of price keys with
  the best price last, so the best level is found/removed in O(1) and levels are
  inserted/removed with `bisect`.
* A level is an intrusive doubly linked FIFO list with a running total
  quantity and order count: cancel/replace unlink an order in O(1), and `BOOK`
  and the FOK availability check read totals in O(1) per level.
* Quantities are Python ints, so sums above 2^32 are exact.

## Tests

```
python3 -m pytest orderbook        # from the parent directory, or just `pytest` here
```
