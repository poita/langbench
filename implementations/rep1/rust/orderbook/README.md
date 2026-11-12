# orderbook

A single-instrument **limit order book matching engine** with price-time
priority, written in Rust using only the standard library. It ships as a
reusable library plus a thin command-line tool that reads a stream of order
commands on stdin and prints the resulting events on stdout.

Supported commands: `LIMIT` (plain, `IOC`, `FOK`), `MARKET`, `CANCEL`,
`REPLACE` and `BOOK`.

## Design

- Each side of the book is a `BTreeMap` from price to level, so the best price
  is found, and an emptied level removed, in O(log P).
- A level is a FIFO queue of orders stored as an intrusive doubly linked list
  in a slab arena: removing an order from the middle (`CANCEL`, or a
  priority-losing `REPLACE`) is O(1).
- Every level keeps its total quantity and order count up to date, so `BOOK`
  lines and FOK availability checks never sum individual orders.
- A hash map from order id to arena slot serves `CANCEL` and `REPLACE`.
- All quantities are `u64`; sums beyond 2^32 are fine.

Source layout:

| module            | responsibility                                         |
|-------------------|--------------------------------------------------------|
| `src/types.rs`    | `Price`, `Qty`, `Side`, `OrderId`                      |
| `src/command.rs`  | `Command`, `TimeInForce` and the text parser           |
| `src/event.rs`    | `Event` output type, text formatting, `EventSink`      |
| `src/level.rs`    | (private) order arena and per-price FIFO queues        |
| `src/book.rs`     | `OrderBook`: matching, FOK, cancel, replace, snapshots |
| `src/io.rs`       | `process`: run a whole text command stream             |
| `src/main.rs`     | the CLI                                                |

## Build

```sh
cargo build --release        # or ./build.sh
```

The binary is `target/release/orderbook`; `./run.sh` runs it from any
directory.

## Command-line use

The program reads all of stdin and writes events to stdout; it takes no
arguments. Input is a line with the command count `N`, followed by `N`
commands:

```
LIMIT <id> <side> <price> <qty> [IOC|FOK]
MARKET <id> <side> <qty>
CANCEL <id>
REPLACE <id> <price> <qty>
BOOK
```

```sh
$ printf '4\nLIMIT s1 SELL 100 5\nLIMIT b1 BUY 101 8\nBOOK\nCANCEL b1\n' | ./run.sh
REST s1
TRADE b1 s1 100 5
FILLED s1
REST b1
BID 101 3 1
--
CANCEL b1 3
```

Output events are `TRADE`, `REST`, `CANCEL`, `REJECT`, `FILLED`, `BID`, `ASK`
and `--`; the exact semantics are those of the problem specification
(`problems/orderbook/SPEC.md`). Exit status is 0 on success, 1 if the input is
malformed or an I/O error occurs.

## Library use

```rust
use orderbook::{Command, Event, OrderBook, OrderId};

fn main() {
    let mut book = OrderBook::new();
    let mut events: Vec<Event> = Vec::new();

    for line in [
        "LIMIT s1 SELL 101 5",
        "LIMIT b1 BUY 102 8",
        "REPLACE b1 102 2",
        "BOOK",
    ] {
        let cmd: Command = line.parse().expect("valid command");
        book.execute(&cmd, &mut events);
    }

    for e in &events {
        println!("{e}"); // REST s1 / TRADE b1 s1 101 5 / FILLED s1 / REST b1 / ...
    }

    let b1 = book.get(&OrderId::new("b1").unwrap()).unwrap();
    assert_eq!(b1.qty, 2);
    assert_eq!(book.best_bid().unwrap().price, 102);
}
```

`OrderBook::execute` takes any `EventSink` — a `Vec<Event>` or a closure
`FnMut(Event)` — so events can be streamed without being collected. To run a
whole text stream, use `orderbook::process(input, writer)`.

## Tests

```sh
cargo test
```

- unit tests in each module;
- `tests/examples.rs`: the worked examples from the specification;
- `tests/differential.rs`: randomised comparison against a naive reference
  model (narrow and wide price ranges, 30-bit quantities);
- `tests/cli.rs`: end-to-end tests of the binary;
- doctests for the public API.

## License

MIT
