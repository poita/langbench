/**
 * Basic vocabulary types shared by every module of the library: prices,
 * quantities, sides, time-in-force flags and the `Event` record the book
 * emits.
 */
module orderbook.types;

/// Limit price, in integer ticks (the CLI accepts 1 .. 1_000_000_000).
alias Price = uint;

/// Quantity. 64-bit because level totals and FOK sums exceed 2^32.
alias Qty = long;

/// Which side of the book an order belongs to.
enum Side : ubyte
{
    /// A bid.
    buy,
    /// An ask.
    sell,
}

/// The other side of the book.
Side opposite(Side s) @safe pure nothrow @nogc
{
    return s == Side.buy ? Side.sell : Side.buy;
}

/// How a limit order treats a remainder that cannot be matched immediately.
enum TimeInForce : ubyte
{
    /// Good till cancelled: the remainder rests in the book (plain `LIMIT`).
    gtc,
    /// Immediate-or-cancel: the remainder is discarded.
    ioc,
    /// Fill-or-kill: rejected unless it can be filled completely.
    fok,
}

/// Kind of an output `Event`.
enum EventKind : ubyte
{
    /// `TRADE <taker> <maker> <price> <qty>`
    trade,
    /// `REST <id>`: the order now rests in the book.
    rest,
    /// `CANCEL <id> <remaining>`: the order left (or never entered) the book.
    cancel,
    /// `REJECT <id>`: the command was refused and nothing changed.
    reject,
    /// `FILLED <id>`: the order's remaining quantity reached zero.
    filled,
    /// `BID <price> <qty> <orders>`: one bid level of a snapshot.
    bid,
    /// `ASK <price> <qty> <orders>`: one ask level of a snapshot.
    ask,
    /// `--`: end of a snapshot.
    endOfBook,
}

/**
 * One output record. Which fields are meaningful depends on `kind`:
 *
 * $(TABLE
 *  $(TR $(TH kind) $(TH fields used))
 *  $(TR $(TD trade) $(TD `id` = taker, `makerId`, `price`, `qty`))
 *  $(TR $(TD rest, filled, reject) $(TD `id`))
 *  $(TR $(TD cancel) $(TD `id`, `qty` = unfilled quantity))
 *  $(TR $(TD bid, ask) $(TD `price`, `qty` = level total, `orders`))
 *  $(TR $(TD endOfBook) $(TD none))
 * )
 *
 * Ids are slices of the strings given to the book; an `Event` does not copy
 * them.
 */
struct Event
{
    EventKind kind;
    string id;
    string makerId;
    Price price;
    Qty qty;
    size_t orders;

    /// Construct a `trade` event.
    static Event trade(string taker, string maker, Price price, Qty qty) @safe pure nothrow @nogc
    {
        return Event(EventKind.trade, taker, maker, price, qty, 0);
    }

    /// Construct a `rest` event.
    static Event rest(string id) @safe pure nothrow @nogc
    {
        return Event(EventKind.rest, id);
    }

    /// Construct a `cancel` event.
    static Event cancel(string id, Qty remaining) @safe pure nothrow @nogc
    {
        return Event(EventKind.cancel, id, null, 0, remaining, 0);
    }

    /// Construct a `reject` event.
    static Event reject(string id) @safe pure nothrow @nogc
    {
        return Event(EventKind.reject, id);
    }

    /// Construct a `filled` event.
    static Event filled(string id) @safe pure nothrow @nogc
    {
        return Event(EventKind.filled, id);
    }

    /// Construct a `bid` or `ask` level event.
    static Event level(Side side, Price price, Qty total, size_t orders) @safe pure nothrow @nogc
    {
        return Event(side == Side.buy ? EventKind.bid : EventKind.ask,
                null, null, price, total, orders);
    }

    /// Construct the `endOfBook` marker.
    static Event endOfBook() @safe pure nothrow @nogc
    {
        return Event(EventKind.endOfBook);
    }

    /// The event in the wire format of the CLI (no trailing newline).
    string toString() const @safe pure
    {
        import orderbook.format : formatEvent;

        return formatEvent(this);
    }
}
