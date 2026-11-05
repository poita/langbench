# orderbook — Limit order book matching engine

Implement a single-instrument limit order book with price-time priority.
Read a stream of order commands from stdin, process them in order, and print
the resulting events to stdout, one per line, exactly as specified below.

The workloads include 200 000-command streams, and books with tens of
thousands of resting orders spread over more than ten thousand price levels
per side, so per-price FIFO queues with a fast way to find and remove the
best price on each side (a sorted structure or a heap over prices) are
expected. Quantities summed per price level and per order exceed 2^32 in
some tests; use 64-bit integers for all quantities.

## Input

Standard input is UTF-8 text (in fact pure ASCII).

- Line 1: an integer `N` (0 ≤ N ≤ 2000000), the number of commands.
- Lines 2 .. N+1: one command per line. Nothing follows line N+1.

Tokens on a command line are separated by exactly one ASCII space. There are
no leading or trailing spaces and no blank lines. Lines end with `\n` (never
`\r\n`; no `\r` appears anywhere); the final line may or may not end with a
newline, and some tests omit it. Every line is well formed and
every command is one of the five below; malformed input never occurs, so no
error handling is required (or tested).

Field formats:

- `<id>`: an order identifier, 1 to 32 characters, each in the printable
  ASCII range `!` (0x21) to `~` (0x7E) — never a space. Ids are opaque and
  compared byte-for-byte; they are printed back verbatim. An id may equal a
  keyword (`BUY`, `SELL`, `BOOK`, `IOC`, ...); tokens are identified purely by
  position. Every `LIMIT`/`MARKET` command in a stream carries an id that no
  earlier `LIMIT`/`MARKET` in that stream used, so an id never denotes two
  different orders. `CANCEL`/`REPLACE` may name any string, including ids
  that were never submitted.
- `<side>`: `BUY` or `SELL`.
- `<price>`: an integer 1 ≤ price ≤ 1000000000, written in decimal with no
  sign and no leading zeros.
- `<qty>`: an integer 1 ≤ qty ≤ 1000000000, same format. Quantities are
  always positive; a quantity of 0 never appears in the input.

Commands:

```
LIMIT <id> <side> <price> <qty>          limit order, remainder rests
LIMIT <id> <side> <price> <qty> IOC      immediate-or-cancel limit order
LIMIT <id> <side> <price> <qty> FOK      fill-or-kill limit order
MARKET <id> <side> <qty>                 market order
CANCEL <id>                              cancel a resting order
REPLACE <id> <price> <qty>               modify a resting order
BOOK                                     print the book
```

## Output

Events, one per line, each terminated by `\n`, with single spaces between
fields and no leading or trailing spaces. When `N` is 0 the output is empty
(zero bytes). All integers are printed in decimal with no sign, no leading
zeros and no separators. Exit code 0.

```
TRADE <taker-id> <maker-id> <price> <qty>   a fill between the incoming (taker)
                                            order and a resting (maker) order
REST <id>                                   the order now rests in the book
CANCEL <id> <remaining-qty>                 the order left the book (or never
                                            entered it) with this much unfilled
REJECT <id>                                 the command was refused; nothing changed
FILLED <id>                                 the order's remaining quantity reached 0
BID <price> <total-qty> <n-orders>          one bid price level (BOOK only)
ASK <price> <total-qty> <n-orders>          one ask price level (BOOK only)
--                                          end of a BOOK listing
```

Every command produces at least one line. The lines for one command are
contiguous and appear in command order.

## The book

The book has two sides. A **resting** order is a limit order (or the
remainder of one) that sits in the book waiting for a counterparty. Resting
BUY orders are **bids**, resting SELL orders are **asks**. On each side,
orders are grouped by price into **levels**; within a level they form a FIFO
queue in the order they started resting.

- The **best bid** is the highest bid price; the **best ask** is the lowest
  ask price.
- An incoming BUY at limit price P **crosses** a resting ask at price Q when
  Q ≤ P. An incoming SELL at limit price P crosses a resting bid at price Q
  when Q ≥ P. A MARKET order crosses every resting order on the opposite
  side. An order never crosses orders on its own side.
- The book can never end up locked or crossed (best bid ≥ best ask), because
  an incoming order fills against everything it crosses before it rests.
- There are no participants or owners: any order may trade against any
  opposite order ("self-match" is not a concept here and is never
  prevented).

## Matching

An incoming order (from `LIMIT`, `MARKET`, or a `REPLACE` that re-enters,
see below) is the **taker**. It is matched as follows:

1. While the taker has remaining quantity and there is a resting order it
   crosses: take the resting order at the **best** opposite price (lowest
   ask for a BUY taker, highest bid for a SELL taker), and within that price
   the **earliest** in the FIFO queue. That order is the **maker**.
2. Trade quantity `t = min(taker remaining, maker remaining)` at the
   **maker's price**. Print `TRADE <taker-id> <maker-id> <maker-price> <t>`.
   Reduce both remainders by `t`.
3. If the maker's remaining is now 0, remove it from the book and print
   `FILLED <maker-id>` immediately after that `TRADE` line.
4. Repeat from 1.

When matching stops, the taker's own final event is printed (this is the
last line for the command):

- remaining 0: `FILLED <taker-id>`
- otherwise, according to the command type (see below).

So the lines for a taker command are: zero or more `TRADE` lines each
optionally followed by `FILLED <maker-id>`, then exactly one final line about
the taker.

## Commands in detail

### `LIMIT <id> <side> <price> <qty>` (no flag)

Match as above with limit price `<price>`. Final line: `FILLED <id>` if fully
filled, otherwise `REST <id>`; in the latter case the remainder joins the
**back** of the FIFO queue at `<price>` on its side (creating the level if
needed).

### `LIMIT ... IOC`

Match exactly as a plain LIMIT. Final line: `FILLED <id>` if fully filled,
otherwise `CANCEL <id> <remaining>` — the remainder is discarded and never
rests. An IOC that fills nothing prints just `CANCEL <id> <qty>`.

### `LIMIT ... FOK`

Before any fill, check whether the total remaining quantity of all resting
orders the taker crosses (every opposite level at a crossing price, all
orders in it) is at least `<qty>`.

- If it is not: print `REJECT <id>` and change nothing — no trades happen,
  nothing rests.
- If it is: match exactly as a plain LIMIT. Since enough quantity is
  available it fills completely, so the lines are the `TRADE`/`FILLED`
  maker lines followed by `FILLED <id>`. An FOK never rests.

### `MARKET <id> <side> <qty>`

Match with no price limit: it takes the best opposite price, then the next,
and so on, until filled or the opposite side is empty. Each trade is at the
maker's price. Final line: `FILLED <id>` if fully filled, otherwise
`CANCEL <id> <remaining>`. A market order never rests, so a MARKET against
an empty opposite side prints just `CANCEL <id> <qty>`.

### `CANCEL <id>`

If `<id>` is a currently resting order: remove it from the book and print
`CANCEL <id> <remaining>` where `<remaining>` is its unfilled quantity (which
is ≥ 1, since a fully filled order is no longer resting).

Otherwise print `REJECT <id>`. "Otherwise" covers every other case: an id
never submitted, an order already fully filled, an order already cancelled,
an order that never rested (IOC/FOK/MARKET, or a FOK that was rejected), and
a second CANCEL of the same order.

### `REPLACE <id> <price> <qty>`

If `<id>` is not a currently resting order (same cases as for CANCEL): print
`REJECT <id>` and change nothing.

Otherwise `<qty>` is the order's **new remaining quantity** (not a delta and
not the original size) and `<price>` its new limit price. Let `P0` and `R0`
be the resting order's current price and remaining quantity.

- **Priority kept** — if `<price> = P0` and `<qty> ≤ R0` (price unchanged
  and quantity not increased; `<qty> = R0` counts): the order stays exactly
  where it is in its FIFO queue with remaining quantity set to `<qty>`.
  Print `REST <id>`.
- **Priority lost** — in every other case (price changed, or quantity
  increased, or both): the order is removed from the book, then re-enters as
  a new plain `LIMIT <id> <side> <price> <qty>` with its **original side**
  and the **same id**. It is matched as a taker (it may trade, including
  against orders that arrived after it) and any remainder joins the back of
  the queue at `<price>`. The lines are exactly those of that LIMIT: the
  `TRADE`/`FILLED` maker lines, then `FILLED <id>` or `REST <id>`.

A REPLACE that changes the price to the same side's existing level (or a new
one) always loses priority, even if the quantity decreases. A REPLACE of a
partially filled order is a REPLACE like any other; only the remaining
quantity matters. After a successful REPLACE the id continues to denote the
same order, so it can be cancelled or replaced again (until it is filled or
cancelled).

### `BOOK`

Print every non-empty bid level, best (highest price) first, one per line
`BID <price> <total-qty> <n-orders>`, then every non-empty ask level, best
(lowest price) first, `ASK <price> <total-qty> <n-orders>`, then a line
containing exactly `--`. `<total-qty>` is the sum of the remaining quantities
of the orders resting at that price and `<n-orders>` their count (≥ 1; a
level with no orders is not printed). An empty book prints just `--`. BOOK
does not change the book.

## Worked examples

### Example 1 — filling across levels, price improvement, FIFO

Input:

    9
    LIMIT s1 SELL 101 5
    LIMIT s2 SELL 103 5
    LIMIT s3 SELL 102 5
    LIMIT s4 SELL 104 5
    LIMIT b1 BUY 103 12
    BOOK
    LIMIT b2 BUY 110 1
    LIMIT b3 BUY 103 9
    BOOK

Output:

    REST s1
    REST s2
    REST s3
    REST s4
    TRADE b1 s1 101 5
    FILLED s1
    TRADE b1 s3 102 5
    FILLED s3
    TRADE b1 s2 103 2
    FILLED b1
    ASK 103 3 1
    ASK 104 5 1
    --
    TRADE b2 s2 103 1
    FILLED b2
    TRADE b3 s2 103 2
    FILLED s2
    REST b3
    BID 103 7 1
    ASK 104 5 1
    --

`b1` (limit 103) takes the asks in price order 101, 102, 103 — each trade at
the maker's price, even though it was willing to pay 103 — and is filled
after 2 of `s2`'s 5. `b2` at 110 trades at 103, the best ask. `b3` takes the
last 2 of `s2` and its remaining 7 rest at 103; the ask at 104 is not
crossed.

### Example 2 — IOC, cancel and replace of a non-resting order

Input:

    11
    LIMIT s1 SELL 100 5
    LIMIT s2 SELL 101 5
    LIMIT b1 BUY 100 8 IOC
    BOOK
    LIMIT b2 BUY 99 8 IOC
    LIMIT b3 BUY 101 5 IOC
    BOOK
    CANCEL b1
    REPLACE b1 100 1
    LIMIT s3 SELL 50 1 IOC
    BOOK

Output:

    REST s1
    REST s2
    TRADE b1 s1 100 5
    FILLED s1
    CANCEL b1 3
    ASK 101 5 1
    --
    CANCEL b2 8
    TRADE b3 s2 101 5
    FILLED s2
    FILLED b3
    --
    REJECT b1
    REJECT b1
    CANCEL s3 1
    --

`b1` fills 5 and its remaining 3 are cancelled rather than rested. `b2`
crosses nothing, so it is cancelled whole. `b3` fills exactly; the maker's
`FILLED` comes right after the trade, the taker's last. `b1` never rested,
so both its CANCEL and REPLACE are rejected. `s3` finds an empty bid side.

### Example 3 — REPLACE priority rules and an aggressive replace

Input:

    10
    LIMIT b1 BUY 100 10
    LIMIT s1 SELL 105 4
    LIMIT s2 SELL 106 4
    REPLACE b1 105 6
    BOOK
    REPLACE b1 110 20
    BOOK
    REPLACE b1 110 3
    CANCEL b1
    BOOK

Output:

    REST b1
    REST s1
    REST s2
    TRADE b1 s1 105 4
    FILLED s1
    REST b1
    BID 105 2 1
    ASK 106 4 1
    --
    TRADE b1 s2 106 4
    FILLED s2
    REST b1
    BID 110 16 1
    --
    REST b1
    CANCEL b1 3
    --

The first REPLACE changes the price, so `b1` re-enters as a new BUY 105 × 6:
it trades 4 against `s1` and rests 2 at 105. The second raises price and
quantity: re-entered as BUY 110 × 20, it takes `s2` and rests 16 at 110. The
third keeps the price and lowers the quantity to 3, so it keeps its place and
just prints `REST`. The CANCEL then reports the remaining 3.

Test 008 in `tests/` shows FIFO within one level: `b1`, `b2`, `b3` (5 each)
rest at 100 in that order, `b4` (2) at 101; a SELL 100 × 7 takes the 2 of
`b4` (best price) then all 5 of `b1` and is filled; the next SELL 100 × 6
takes all of `b2` before 1 from `b3`.

## Limits

- N ≤ 2000000 commands; each test's total output is under 100 MB.
- Up to about 45 000 orders rest at once, across up to about 12 000 distinct
  price levels per side.
- Individual prices and quantities fit in 32 bits, but sums of quantities
  (a level's `<total-qty>`, and the quantity available to a FOK across the
  levels it crosses) exceed 2^32 in some tests and fit in a signed 64-bit
  integer; use 64-bit integers for every sum.
