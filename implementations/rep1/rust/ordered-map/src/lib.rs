//! # ordered-map
//!
//! An ordered map from `i64` keys to arbitrary values, implemented as an
//! AVL tree augmented with subtree sizes.
//!
//! Every operation — insertion, removal, lookup, order statistics
//! ([`OrderedMap::rank`], [`OrderedMap::select`]) and neighbour queries
//! ([`OrderedMap::floor`], [`OrderedMap::ceil`], [`OrderedMap::successor`],
//! [`OrderedMap::predecessor`]) — runs in `O(log n)`. Range iteration
//! ([`OrderedMap::range`]) costs `O(log n + r)` for `r` reported entries.
//!
//! The crate is organised as:
//!
//! * [`map`] — the [`OrderedMap`] data structure itself;
//! * [`iter`] — in-order and range iterators;
//! * [`command`] — parsing of the textual command language used by the CLI;
//! * [`exec`] — executing parsed commands against a map and rendering output.
//!
//! ```
//! use ordered_map::OrderedMap;
//!
//! let mut m = OrderedMap::new();
//! m.insert(10, "a");
//! m.insert(20, "b");
//! m.insert(30, "c");
//! assert_eq!(m.floor(25), Some(20));
//! assert_eq!(m.rank(21), 2);
//! assert_eq!(m.select(2), Some(30));
//! assert_eq!(m.range(10..=20).map(|(k, _)| k).collect::<Vec<_>>(), [10, 20]);
//! ```

pub mod command;
pub mod exec;
pub mod iter;
pub mod map;

pub use command::{Command, ParseError};
pub use exec::{execute, run};
pub use map::OrderedMap;
