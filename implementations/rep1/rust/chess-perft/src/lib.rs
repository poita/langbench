//! A legal chess move generator with [perft](https://www.chessprogramming.org/Perft)
//! and *divide*.
//!
//! The crate is organised by responsibility:
//!
//! * [`types`] — [`Color`], [`PieceKind`], [`Square`];
//! * [`bitboard`] — the [`Bitboard`] square set;
//! * [`attacks`] — compile-time attack, between and line tables;
//! * [`moves`] — [`Move`], [`MoveList`] and the [`MoveSink`] trait;
//! * [`position`] — [`Position`]: FEN parsing and move making;
//! * [`movegen`] — legal move generation from check and pin information;
//! * [`perft`] — [`perft()`] and [`divide()`];
//! * [`query`] — the text query format used by the CLI.
//!
//! # Example
//!
//! ```
//! use chess_perft::{perft, Position};
//!
//! let pos = Position::startpos();
//! assert_eq!(pos.legal_moves().len(), 20);
//! assert_eq!(perft(&pos, 3), 8902);
//! ```

pub mod attacks;
pub mod bitboard;
pub mod error;
pub mod movegen;
pub mod moves;
pub mod perft;
pub mod position;
pub mod query;
pub mod types;

pub use bitboard::Bitboard;
pub use error::ParseError;
pub use moves::{Move, MoveCounter, MoveKind, MoveList, MoveSink};
pub use perft::{divide, perft};
pub use position::{Castling, Position};
pub use types::{Color, PieceKind, Square};
