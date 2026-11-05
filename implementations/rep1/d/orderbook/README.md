# orderbook

A single-instrument limit order book matching engine with price-time priority,
written in D. It ships as a small library (`orderbook`) and a thin
command-line tool that reads order commands on stdin and prints the resulting
events on stdout. `LIMIT` (GTC/IOC/FOK), `MARKET`, `CANCEL`, `REPLACE` and
`BOOK` are supported; all quantities are 64-bit.

## Design

The input is parsed in one pass into a flat command array (order ids stay as
slices of the input buffer). All prices are collected, sorted and ranked, so
each side of the book is a dense array of price levels indexed by rank, with a
segment tree on top that finds the best level, sums crossing liquidity (for
FOK) and walks non-empty levels (for `BOOK`) in O(log P). Resting orders live
in an arena with intrusive FIFO links per level, and a hash map finds them by
id. Matching, cancelling and replacing are O(1) plus a tree refresh per level.

| Module                | Responsibility                                   |
|-----------------------|--------------------------------------------------|
| `orderbook.types`     | `Side`, `Tif`, `CmdKind`, `Command`              |
| `orderbook.parser`    | hand-written text command parser                 |
| `orderbook.pricetable`| price compression (price <-> rank)              |
| `orderbook.leveltree` | segment tree over price levels                   |
| `orderbook.idmap`     | open-addressing hash map from id bytes to index  |
| `orderbook.outbuf`    | output buffer with integer formatting            |
| `orderbook.book`      | `Book`, the matching engine                      |
| `orderbook.driver`    | `processStream`: whole text input to text output |

## Build and test

Requires LDC 1.41.0 and dub 1.40.0.

```
./build.sh                                  # dub build -b release --compiler=ldc2
dub test --compiler=ldc2                    # unit tests (in tests/)
python3 ../run_tests.py orderbook -- orderbook/run.sh   # from the parent dir
```

`dub build` produces the `orderbook` executable; the `library` configuration
builds only the library (`dub build --config=library`).

## Command-line usage

```
./run.sh < commands.txt > events.txt
```

Input is a count line `N` followed by `N` command lines:

```
LIMIT <id> <BUY|SELL> <price> <qty> [IOC|FOK]
MARKET <id> <BUY|SELL> <qty>
CANCEL <id>
REPLACE <id> <price> <qty>
BOOK
```

Output events are `TRADE`, `REST`, `CANCEL`, `REJECT`, `FILLED`, `BID`, `ASK`
and `--`, one per line. Example:

```
$ printf '3\nLIMIT s1 SELL 101 5\nLIMIT b1 BUY 102 3\nBOOK\n' | ./run.sh
REST s1
TRADE b1 s1 101 3
FILLED b1
ASK 101 2 1
--
```

The exact format and rules are specified in `../problems/orderbook/SPEC.md`.

## Library example

A `Book` is created for a fixed set of prices (a `PriceTable`); order ids are
borrowed slices and must outlive the orders they name. Events are appended to
an `OutBuf`.

```d
import orderbook;
import std.stdio : write;

void main()
{
    auto book = Book(PriceTable.from([100, 101, 102]));
    OutBuf out_;

    book.limit("s1", Side.sell, 101, 5, Tif.gtc, out_);
    book.limit("b1", Side.buy, 102, 3, Tif.gtc, out_);
    book.replace("s1", 101, 1, out_);   // keeps queue priority
    book.printBook(out_);

    write(cast(const(char)[]) out_.data);
}
```

To process a textual stream directly, use `processStream(input, output)` (or
`processToString`) from `orderbook.driver`.
