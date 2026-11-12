/**
 * A limit order book matching engine with price-time priority.
 *
 * Import `orderbook` to get everything:
 *
 * $(UL
 *  $(LI `orderbook.types`: `Side`, `Price`, `Qty`, `Event`, ...)
 *  $(LI `orderbook.book`: the `OrderBook` matching engine)
 *  $(LI `orderbook.command`: parse and execute the text command language)
 *  $(LI `orderbook.format`: render events as text, buffered output)
 * )
 */
module orderbook;

public import orderbook.book;
public import orderbook.command;
public import orderbook.format;
public import orderbook.types;
