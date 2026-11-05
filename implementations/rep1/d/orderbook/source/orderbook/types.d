/++
Basic value types shared by every module of the library: order side,
time-in-force, command kinds and the parsed `Command` record.
+/
module orderbook.types;

/// Which side of the book an order belongs to.
enum Side : ubyte
{
    /// A bid (buy) order.
    buy,
    /// An ask (sell) order.
    sell,
}

/// Time-in-force of a limit order.
enum Tif : ubyte
{
    /// Good-till-cancelled: the unfilled remainder rests in the book.
    gtc,
    /// Immediate-or-cancel: the unfilled remainder is discarded.
    ioc,
    /// Fill-or-kill: the order trades completely or is rejected untouched.
    fok,
}

/// The five commands understood by the engine.
enum CmdKind : ubyte
{
    limit,
    market,
    cancel,
    replace,
    book,
}

/// Index used for "no order" in intrusive lists.
enum int nil = -1;

/++
One parsed input command.

Order identifiers are *borrowed*: `idOff`/`idLen` locate the id inside the
input buffer the command was parsed from, which must therefore outlive every
use of the command. `rank` is the dense rank of `price` in the stream's
`PriceTable`; it is filled in by `PriceTable.assignRanks`.
+/
struct Command
{
    uint idOff;
    uint price;
    uint qty;
    uint rank;
    CmdKind kind;
    Side side;
    Tif tif;
    ubyte idLen;
}
