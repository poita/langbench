# orderbook

A single-instrument **limit order book matching engine** with price-time
priority, written in C++20 with no dependencies beyond the standard library.
It ships as a small reusable library plus a command-line tool that reads a
stream of order commands and prints the resulting events.

Supported: limit orders (plain, IOC, FOK), market orders, cancel, replace
(with priority rules), and book snapshots. All quantities and sums are 64-bit.

## Layout

| Path | Contents |
| --- | --- |
| `include/orderbook/types.hpp` | `Price`, `Qty`, `Side`, `TimeInForce` |
| `include/orderbook/event.hpp` | `EventSink` interface, `Event`, `RecordingSink` |
| `include/orderbook/order_book.hpp` | `OrderBook`: matching, cancel, replace, snapshot |
| `include/orderbook/command.hpp` | `Command` and `parse_command()` for the text protocol |
| `include/orderbook/text_writer.hpp` | `TextEventWriter`: events rendered as text lines |
| `include/orderbook/session.hpp` | `run_session()`: a whole input stream in, text out |
| `include/orderbook/detail/` | internal: intrusive-list `Order`/`Level`, ordered `BookSide` |
| `cli/main.cpp` | the command-line tool (thin wrapper over `run_session`) |
| `examples/library_usage.cpp` | library example |
| `tests/` | GoogleTest unit, end-to-end and randomized differential tests |

## Design

* Each side is a `std::map` of price levels ordered best-first, so the best
  level is `begin()` and removing an emptied level is O(log P).
* A level keeps an intrusive doubly linked FIFO of orders plus its total
  quantity and order count, so cancels and priority-losing replaces unlink an
  order in O(1), and FOK checks and `BOOK` lines read totals in O(1) per level.
* A hash map from id to resting order serves `CANCEL` / `REPLACE`; orders are
  pooled and recycled to avoid per-order allocation.
* Matching reports through an `EventSink`, so the engine is independent of
  the text format.

## Build

Requires CMake >= 3.20, a C++20 compiler and (for tests) GoogleTest.

```sh
./build.sh                      # Release build into ./build
ctest --test-dir build          # run the unit tests
```

or by hand: `cmake -S . -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build`.
Options: `-DORDERBOOK_BUILD_TESTS=OFF`, `-DORDERBOOK_BUILD_EXAMPLES=OFF`.
The CLI is built as `build/orderbook`; `./run.sh` runs it from any directory.

## Command-line use

Reads commands from stdin, writes events to stdout (exit code 1 and a message
on stderr if the input is malformed).

```
$ printf '3\nLIMIT s1 SELL 101 5\nLIMIT b1 BUY 102 3\nBOOK\n' | ./run.sh
REST s1
TRADE b1 s1 101 3
FILLED b1
ASK 101 2 1
--
```

Input: a line with `N`, then `N` lines, each one of

```
LIMIT <id> <BUY|SELL> <price> <qty> [IOC|FOK]
MARKET <id> <BUY|SELL> <qty>
CANCEL <id>
REPLACE <id> <price> <qty>
BOOK
```

Output events: `TRADE <taker> <maker> <price> <qty>`, `REST <id>`,
`CANCEL <id> <remaining>`, `REJECT <id>`, `FILLED <id>`,
`BID|ASK <price> <total-qty> <n-orders>` and `--`. Matching trades at the
maker's price; `REPLACE` keeps queue position only if the price is unchanged
and the quantity is not increased, otherwise the order re-enters as a new
limit order. The complete rules are in the problem's `SPEC.md`.

## Library example

```cpp
#include <iostream>
#include "orderbook/order_book.hpp"
#include "orderbook/text_writer.hpp"

int main() {
  using namespace orderbook;
  OrderBook book;
  TextEventWriter out(std::cout);   // or RecordingSink to get events as data

  book.limit("s1", Side::Sell, 101, 5, TimeInForce::GoodTillCancel, out);
  book.limit("b1", Side::Buy, 102, 8, TimeInForce::GoodTillCancel, out);  // trade, then rests
  book.replace("b1", 100, 2, out);   // price changed: re-enters as a new order
  book.cancel("b1", out);
  book.snapshot(out);
}
```

Link against the `orderbook::orderbook` CMake target (`add_subdirectory`).
See `examples/library_usage.cpp` for a fuller version.

## Tests

`ctest --test-dir build` (or run `build/orderbook-tests`) covers the parser,
every matching rule, the 64-bit sum cases, the stream session, and a
randomized differential test against a naive reference model.
