//! The order book itself.

use crate::command::{Command, TimeInForce};
use crate::event::{Event, EventSink};
use crate::level::{Arena, Level, NIL};
use crate::types::{OrderId, Price, Qty, Side};
use std::collections::{BTreeMap, HashMap};

/// Aggregate view of one price level, as printed by `BOOK`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct LevelInfo {
    /// Level price.
    pub price: Price,
    /// Sum of the remaining quantities of the orders at the level.
    pub qty: Qty,
    /// Number of orders at the level.
    pub orders: u32,
}

/// A snapshot of one resting order.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct RestingOrder {
    /// The order's id.
    pub id: OrderId,
    /// Its side.
    pub side: Side,
    /// Its limit price.
    pub price: Price,
    /// Its remaining quantity.
    pub qty: Qty,
}

/// A single-instrument limit order book with price-time priority.
///
/// Each side is a `BTreeMap` from price to [`Level`]; a level is a FIFO queue
/// of orders held in an arena, with O(1) removal from the middle and running
/// quantity totals. A hash map from order id to arena slot serves `CANCEL`
/// and `REPLACE`.
///
/// ```
/// use orderbook::{Command, Event, OrderBook};
///
/// let mut book = OrderBook::new();
/// let mut events = Vec::new();
/// book.execute(&Command::parse("LIMIT s1 SELL 100 5").unwrap(), &mut events);
/// book.execute(&Command::parse("LIMIT b1 BUY 100 3").unwrap(), &mut events);
/// let lines: Vec<String> = events.iter().map(|e| e.to_string()).collect();
/// assert_eq!(lines, ["REST s1", "TRADE b1 s1 100 3", "FILLED b1"]);
/// ```
#[derive(Default)]
pub struct OrderBook {
    bids: BTreeMap<Price, Level>,
    asks: BTreeMap<Price, Level>,
    arena: Arena,
    index: HashMap<OrderId, u32>,
}

impl OrderBook {
    /// Creates an empty book.
    pub fn new() -> OrderBook {
        OrderBook::default()
    }

    /// Executes one command, sending the resulting events to `sink`.
    ///
    /// Every command emits at least one event.
    pub fn execute<S: EventSink>(&mut self, cmd: &Command, sink: &mut S) {
        match *cmd {
            Command::Limit { id, side, price, qty, tif } => match tif {
                TimeInForce::Gtc => {
                    let rem = self.match_taker(id, side, Some(price), qty, sink);
                    self.finish_limit(id, side, price, rem, sink);
                }
                TimeInForce::Ioc => {
                    let rem = self.match_taker(id, side, Some(price), qty, sink);
                    Self::finish_unrested(id, rem, sink);
                }
                TimeInForce::Fok => {
                    if self.crossable_qty(side, price, qty) >= qty {
                        let rem = self.match_taker(id, side, Some(price), qty, sink);
                        debug_assert_eq!(rem, 0);
                        Self::finish_unrested(id, rem, sink);
                    } else {
                        sink.emit(Event::Reject(id));
                    }
                }
            },
            Command::Market { id, side, qty } => {
                let rem = self.match_taker(id, side, None, qty, sink);
                Self::finish_unrested(id, rem, sink);
            }
            Command::Cancel { id } => self.cancel(id, sink),
            Command::Replace { id, price, qty } => self.replace(id, price, qty, sink),
            Command::Book => self.print_book(sink),
        }
    }

    /// Best (highest) bid level, if any.
    pub fn best_bid(&self) -> Option<LevelInfo> {
        self.bids.iter().next_back().map(|(&p, l)| info(p, l))
    }

    /// Best (lowest) ask level, if any.
    pub fn best_ask(&self) -> Option<LevelInfo> {
        self.asks.iter().next().map(|(&p, l)| info(p, l))
    }

    /// Non-empty levels of `side`, best price first.
    pub fn levels(&self, side: Side) -> Box<dyn Iterator<Item = LevelInfo> + '_> {
        match side {
            Side::Buy => Box::new(self.bids.iter().rev().map(|(&p, l)| info(p, l))),
            Side::Sell => Box::new(self.asks.iter().map(|(&p, l)| info(p, l))),
        }
    }

    /// Looks up a resting order by id.
    pub fn get(&self, id: &OrderId) -> Option<RestingOrder> {
        let &slot = self.index.get(id)?;
        let n = self.arena.get(slot);
        Some(RestingOrder { id: n.id, side: n.side, price: n.price, qty: n.qty })
    }

    /// Number of resting orders.
    pub fn len(&self) -> usize {
        self.index.len()
    }

    /// Whether no orders rest in the book.
    pub fn is_empty(&self) -> bool {
        self.index.is_empty()
    }

    /// Total remaining quantity a taker on `side` with limit `limit` could
    /// trade against, stopping early once `needed` is reached.
    fn crossable_qty(&self, side: Side, limit: Price, needed: Qty) -> Qty {
        let mut sum: Qty = 0;
        let mut add = |l: &Level| {
            sum += l.total;
            sum >= needed
        };
        match side {
            Side::Buy => {
                for (_, l) in self.asks.range(..=limit) {
                    if add(l) {
                        break;
                    }
                }
            }
            Side::Sell => {
                for (_, l) in self.bids.range(limit..).rev() {
                    if add(l) {
                        break;
                    }
                }
            }
        }
        sum
    }

    /// Matches a taker against the opposite side; returns its remaining quantity.
    fn match_taker<S: EventSink>(
        &mut self,
        taker: OrderId,
        side: Side,
        limit: Option<Price>,
        qty: Qty,
        sink: &mut S,
    ) -> Qty {
        let mut rem = qty;
        let opposite = match side {
            Side::Buy => &mut self.asks,
            Side::Sell => &mut self.bids,
        };
        while rem > 0 {
            let entry = match side {
                Side::Buy => opposite.first_entry(),
                Side::Sell => opposite.last_entry(),
            };
            let Some(mut entry) = entry else { break };
            let price = *entry.key();
            if limit.is_some_and(|l| !side.crosses(l, price)) {
                break;
            }
            let level = entry.get_mut();
            while rem > 0 && level.head != NIL {
                let slot = level.head;
                let maker = self.arena.get_mut(slot);
                let t = rem.min(maker.qty);
                let maker_id = maker.id;
                maker.qty -= t;
                let maker_done = maker.qty == 0;
                rem -= t;
                level.total -= t;
                sink.emit(Event::Trade { taker, maker: maker_id, price, qty: t });
                if maker_done {
                    level.unlink(&mut self.arena, slot);
                    self.arena.release(slot);
                    self.index.remove(&maker_id);
                    sink.emit(Event::Filled(maker_id));
                }
            }
            if level.is_empty() {
                entry.remove();
            }
        }
        rem
    }

    /// Final event of a plain LIMIT (or re-entered REPLACE): fill or rest.
    fn finish_limit<S: EventSink>(
        &mut self,
        id: OrderId,
        side: Side,
        price: Price,
        rem: Qty,
        sink: &mut S,
    ) {
        if rem == 0 {
            sink.emit(Event::Filled(id));
            return;
        }
        let slot = self.arena.alloc(id, side, price, rem);
        let book = match side {
            Side::Buy => &mut self.bids,
            Side::Sell => &mut self.asks,
        };
        book.entry(price).or_insert_with(Level::new).push_back(&mut self.arena, slot);
        self.index.insert(id, slot);
        sink.emit(Event::Rest(id));
    }

    /// Final event of an order that never rests (IOC, FOK, MARKET).
    fn finish_unrested<S: EventSink>(id: OrderId, rem: Qty, sink: &mut S) {
        if rem == 0 {
            sink.emit(Event::Filled(id));
        } else {
            sink.emit(Event::Cancel { id, remaining: rem });
        }
    }

    /// Removes a resting order from its level (dropping the level if it
    /// becomes empty) and from the id index; returns what it was.
    fn remove_resting(&mut self, id: OrderId) -> Option<RestingOrder> {
        let slot = self.index.remove(&id)?;
        let n = self.arena.get(slot);
        let order = RestingOrder { id, side: n.side, price: n.price, qty: n.qty };
        let book = match order.side {
            Side::Buy => &mut self.bids,
            Side::Sell => &mut self.asks,
        };
        let level = book.get_mut(&order.price).expect("resting order has a level");
        level.unlink(&mut self.arena, slot);
        if level.is_empty() {
            book.remove(&order.price);
        }
        self.arena.release(slot);
        Some(order)
    }

    fn cancel<S: EventSink>(&mut self, id: OrderId, sink: &mut S) {
        match self.remove_resting(id) {
            Some(o) => sink.emit(Event::Cancel { id, remaining: o.qty }),
            None => sink.emit(Event::Reject(id)),
        }
    }

    fn replace<S: EventSink>(&mut self, id: OrderId, price: Price, qty: Qty, sink: &mut S) {
        let Some(&slot) = self.index.get(&id) else {
            sink.emit(Event::Reject(id));
            return;
        };
        let node = self.arena.get_mut(slot);
        if node.price == price && qty <= node.qty {
            // Priority kept: adjust in place.
            let diff = node.qty - qty;
            let side = node.side;
            node.qty = qty;
            let book = match side {
                Side::Buy => &mut self.bids,
                Side::Sell => &mut self.asks,
            };
            book.get_mut(&price).expect("resting order has a level").total -= diff;
            sink.emit(Event::Rest(id));
        } else {
            let old = self.remove_resting(id).expect("order is resting");
            let rem = self.match_taker(id, old.side, Some(price), qty, sink);
            self.finish_limit(id, old.side, price, rem, sink);
        }
    }

    fn print_book<S: EventSink>(&self, sink: &mut S) {
        for (&price, l) in self.bids.iter().rev() {
            sink.emit(Event::Bid { price, qty: l.total, orders: l.count });
        }
        for (&price, l) in self.asks.iter() {
            sink.emit(Event::Ask { price, qty: l.total, orders: l.count });
        }
        sink.emit(Event::EndOfBook);
    }
}

fn info(price: Price, l: &Level) -> LevelInfo {
    LevelInfo { price, qty: l.total, orders: l.count }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn run(book: &mut OrderBook, lines: &[&str]) -> Vec<String> {
        let mut ev = Vec::new();
        for l in lines {
            book.execute(&Command::parse(l).unwrap(), &mut ev);
        }
        ev.iter().map(|e| e.to_string()).collect()
    }

    #[test]
    fn fok_rejects_without_side_effects() {
        let mut b = OrderBook::new();
        let out = run(&mut b, &["LIMIT s1 SELL 100 5", "LIMIT f1 BUY 100 6 FOK", "BOOK"]);
        assert_eq!(out, ["REST s1", "REJECT f1", "ASK 100 5 1", "--"]);
    }

    #[test]
    fn fok_counts_only_crossing_levels() {
        let mut b = OrderBook::new();
        let out = run(
            &mut b,
            &["LIMIT s1 SELL 100 5", "LIMIT s2 SELL 102 5", "LIMIT f BUY 101 6 FOK", "LIMIT g BUY 102 10 FOK"],
        );
        assert_eq!(out[2], "REJECT f");
        assert_eq!(&out[3..], ["TRADE g s1 100 5", "FILLED s1", "TRADE g s2 102 5", "FILLED s2", "FILLED g"]);
        assert!(b.is_empty());
    }

    #[test]
    fn replace_keeps_priority_only_when_allowed() {
        let mut b = OrderBook::new();
        let out = run(
            &mut b,
            &["LIMIT a BUY 10 5", "LIMIT c BUY 10 5", "REPLACE a 10 3", "LIMIT s SELL 10 3",
              "REPLACE a 10 4", "LIMIT t SELL 10 1"],
        );
        // a keeps its place after the decrease, so s trades with a; then a is
        // filled, so the REPLACE is rejected.
        assert_eq!(out[3..6], ["TRADE s a 10 3", "FILLED a", "FILLED s"]);
        assert_eq!(out[6], "REJECT a");
        assert_eq!(out[7..], ["TRADE t c 10 1", "FILLED t"]);
    }

    #[test]
    fn replace_to_larger_goes_to_back() {
        let mut b = OrderBook::new();
        let out = run(&mut b, &["LIMIT a BUY 10 5", "LIMIT c BUY 10 5", "REPLACE a 10 6", "LIMIT s SELL 10 1"]);
        assert_eq!(out[2..], ["REST a", "TRADE s c 10 1", "FILLED s"]);
    }

    #[test]
    fn queries() {
        let mut b = OrderBook::new();
        run(&mut b, &["LIMIT a BUY 10 5", "LIMIT c SELL 12 2"]);
        assert_eq!(b.best_bid(), Some(LevelInfo { price: 10, qty: 5, orders: 1 }));
        assert_eq!(b.best_ask(), Some(LevelInfo { price: 12, qty: 2, orders: 1 }));
        assert_eq!(b.len(), 2);
        let o = b.get(&OrderId::new("a").unwrap()).unwrap();
        assert_eq!((o.side, o.price, o.qty), (Side::Buy, 10, 5));
        assert_eq!(b.levels(Side::Buy).count(), 1);
    }

    #[test]
    fn id_may_equal_keyword() {
        let mut b = OrderBook::new();
        let out = run(&mut b, &["LIMIT BOOK BUY 5 1", "CANCEL BOOK", "CANCEL BOOK"]);
        assert_eq!(out, ["REST BOOK", "CANCEL BOOK 1", "REJECT BOOK"]);
    }
}
