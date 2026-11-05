/++
$(B orderbook) — a single-instrument limit order book with price-time priority.

Import `orderbook` to get the whole public API:

$(UL
  $(LI `orderbook.types`: `Side`, `Tif`, `CmdKind`, `Command`)
  $(LI `orderbook.parser`: `parseCommands` for the text command format)
  $(LI `orderbook.pricetable`: `PriceTable`, offline price compression)
  $(LI `orderbook.leveltree`: `LevelTree`, segment tree over price levels)
  $(LI `orderbook.idmap`: `IdMap`, id -> arena index hash map)
  $(LI `orderbook.outbuf`: `OutBuf`, the event output buffer)
  $(LI `orderbook.book`: `Book`, the matching engine)
  $(LI `orderbook.driver`: `processStream`, text in / text out)
)
+/
module orderbook;

public import orderbook.types;
public import orderbook.parser;
public import orderbook.pricetable;
public import orderbook.leveltree;
public import orderbook.idmap;
public import orderbook.outbuf;
public import orderbook.book;
public import orderbook.driver;
