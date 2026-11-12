// Package orderbook implements a single-instrument limit order book with
// price-time priority.
//
// A [Book] holds resting orders grouped into price levels on a bid and an ask
// side. Orders are submitted with [Book.Limit], [Book.Market], [Book.Cancel]
// and [Book.Replace] (or generically through [Book.Execute]); each call
// returns the [Event] values it produced, in order, exactly as a matching
// engine would report them: trades, fills, rests, cancels and rejects.
//
// # Design
//
// Each side keeps its price levels in a treap ordered by price, plus a hash
// map from price to level and a cached pointer to the best level. A level owns
// an intrusive doubly linked FIFO queue of orders together with the total
// resting quantity and the order count. Consequently:
//
//   - finding the best price is O(1) and removing an emptied best level is
//     O(log P);
//   - removing an order from the middle of a queue is O(1);
//   - level totals are always current, so a fill-or-kill check and a
//     [Book.Snapshot] read them in O(1) per level.
//
// All quantities are 64-bit; sums of 32-bit quantities never overflow.
//
// A Book is not safe for concurrent use.
package orderbook
