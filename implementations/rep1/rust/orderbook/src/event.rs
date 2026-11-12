//! Output events produced by the engine, and the [`EventSink`] trait that
//! receives them.

use crate::types::{OrderId, Price, Qty};
use std::fmt;

/// One line of output.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Event {
    /// A fill between the incoming order and a resting order, at the maker's price.
    Trade {
        /// The incoming order.
        taker: OrderId,
        /// The resting order.
        maker: OrderId,
        /// The maker's price.
        price: Price,
        /// Traded quantity.
        qty: Qty,
    },
    /// The order now rests in the book.
    Rest(OrderId),
    /// The order left the book (or never entered it) with `remaining` unfilled.
    Cancel {
        /// The order.
        id: OrderId,
        /// Unfilled quantity.
        remaining: Qty,
    },
    /// The command was refused; nothing changed.
    Reject(OrderId),
    /// The order's remaining quantity reached zero.
    Filled(OrderId),
    /// One bid level of a `BOOK` listing.
    Bid {
        /// Level price.
        price: Price,
        /// Sum of remaining quantities at the level.
        qty: Qty,
        /// Number of orders at the level.
        orders: u32,
    },
    /// One ask level of a `BOOK` listing.
    Ask {
        /// Level price.
        price: Price,
        /// Sum of remaining quantities at the level.
        qty: Qty,
        /// Number of orders at the level.
        orders: u32,
    },
    /// End of a `BOOK` listing (`--`).
    EndOfBook,
}

fn push_u64(out: &mut Vec<u8>, mut n: u64) {
    let mut buf = [0u8; 20];
    let mut i = buf.len();
    loop {
        i -= 1;
        buf[i] = b'0' + (n % 10) as u8;
        n /= 10;
        if n == 0 {
            break;
        }
    }
    out.extend_from_slice(&buf[i..]);
}

impl Event {
    /// Appends the event's text (without the trailing newline) to `out`.
    pub fn write_to(&self, out: &mut Vec<u8>) {
        match self {
            Event::Trade { taker, maker, price, qty } => {
                out.extend_from_slice(b"TRADE ");
                out.extend_from_slice(taker.as_bytes());
                out.push(b' ');
                out.extend_from_slice(maker.as_bytes());
                out.push(b' ');
                push_u64(out, *price);
                out.push(b' ');
                push_u64(out, *qty);
            }
            Event::Rest(id) => {
                out.extend_from_slice(b"REST ");
                out.extend_from_slice(id.as_bytes());
            }
            Event::Cancel { id, remaining } => {
                out.extend_from_slice(b"CANCEL ");
                out.extend_from_slice(id.as_bytes());
                out.push(b' ');
                push_u64(out, *remaining);
            }
            Event::Reject(id) => {
                out.extend_from_slice(b"REJECT ");
                out.extend_from_slice(id.as_bytes());
            }
            Event::Filled(id) => {
                out.extend_from_slice(b"FILLED ");
                out.extend_from_slice(id.as_bytes());
            }
            Event::Bid { price, qty, orders } | Event::Ask { price, qty, orders } => {
                out.extend_from_slice(if matches!(self, Event::Bid { .. }) {
                    b"BID "
                } else {
                    b"ASK "
                });
                push_u64(out, *price);
                out.push(b' ');
                push_u64(out, *qty);
                out.push(b' ');
                push_u64(out, u64::from(*orders));
            }
            Event::EndOfBook => out.extend_from_slice(b"--"),
        }
    }
}

impl fmt::Display for Event {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let mut buf = Vec::with_capacity(64);
        self.write_to(&mut buf);
        f.write_str(std::str::from_utf8(&buf).expect("events are ASCII"))
    }
}

/// Receiver of the events the engine emits while executing a command.
///
/// Implemented for `Vec<Event>` (collect everything) and for any
/// `FnMut(Event)` closure.
pub trait EventSink {
    /// Called once per output line, in output order.
    fn emit(&mut self, event: Event);
}

impl EventSink for Vec<Event> {
    #[inline]
    fn emit(&mut self, event: Event) {
        self.push(event);
    }
}

impl<F: FnMut(Event)> EventSink for F {
    #[inline]
    fn emit(&mut self, event: Event) {
        self(event)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn id(s: &str) -> OrderId {
        OrderId::new(s).unwrap()
    }

    #[test]
    fn display_formats() {
        let t = Event::Trade { taker: id("b1"), maker: id("s1"), price: 101, qty: 5_000_000_000 };
        assert_eq!(t.to_string(), "TRADE b1 s1 101 5000000000");
        assert_eq!(Event::Rest(id("x")).to_string(), "REST x");
        assert_eq!(Event::Cancel { id: id("x"), remaining: 3 }.to_string(), "CANCEL x 3");
        assert_eq!(Event::Reject(id("x")).to_string(), "REJECT x");
        assert_eq!(Event::Filled(id("x")).to_string(), "FILLED x");
        assert_eq!(Event::Bid { price: 1, qty: 0, orders: 2 }.to_string(), "BID 1 0 2");
        assert_eq!(Event::Ask { price: 9, qty: u64::MAX, orders: 1 }.to_string(),
                   "ASK 9 18446744073709551615 1");
        assert_eq!(Event::EndOfBook.to_string(), "--");
    }

    #[test]
    fn closure_sink() {
        let mut n = 0;
        let mut sink = |_e: Event| n += 1;
        sink.emit(Event::EndOfBook);
        sink.emit(Event::EndOfBook);
        assert_eq!(n, 2);
    }
}
