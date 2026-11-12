//! A single-instrument limit order book matching engine with price-time
//! priority.
//!
//! The crate is organised by responsibility:
//!
//! - [`types`]: prices, quantities, [`Side`] and [`OrderId`];
//! - [`command`]: the [`Command`] enum and its text parser;
//! - [`event`]: the [`Event`] output enum and the [`EventSink`] trait;
//! - [`book`]: the [`OrderBook`] matching engine;
//! - [`io`]: [`process`], which runs a text command stream end to end.
//!
//! ```
//! use orderbook::{Command, OrderBook};
//!
//! let mut book = OrderBook::new();
//! let mut events = Vec::new();
//! for line in ["LIMIT s1 SELL 101 5", "LIMIT b1 BUY 102 8", "BOOK"] {
//!     book.execute(&line.parse::<Command>().unwrap(), &mut events);
//! }
//! let text: Vec<String> = events.iter().map(|e| e.to_string()).collect();
//! assert_eq!(
//!     text,
//!     ["REST s1", "TRADE b1 s1 101 5", "FILLED s1", "REST b1", "BID 102 3 1", "--"]
//! );
//! ```

pub mod book;
pub mod command;
pub mod event;
pub mod io;
mod level;
pub mod types;

pub use book::{LevelInfo, OrderBook, RestingOrder};
pub use command::{Command, ParseError, TimeInForce};
pub use event::{Event, EventSink};
pub use io::{process, ProcessError};
pub use types::{InvalidId, OrderId, Price, Qty, Side, MAX_ID_LEN};
