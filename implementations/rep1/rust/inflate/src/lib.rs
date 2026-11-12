//! A from-scratch decoder for raw DEFLATE streams ([RFC 1951]).
//!
//! The main entry point is [`inflate`], which turns a raw DEFLATE byte stream
//! into the decompressed bytes or an [`Error`] describing the first
//! malformation. Huffman codes are decoded with two-level lookup tables
//! ([`huffman`]), the input is read with an LSB-first [`bitreader`], and the
//! [`hex`] module provides the text encoding used by the command-line tool.
//!
//! ```
//! // A fixed-Huffman block: literals "abc", then a copy of 6 bytes at distance 3.
//! let compressed = inflate::hex::decode(b"4b4c4a862000").unwrap();
//! let output = inflate::inflate(&compressed).unwrap();
//! assert_eq!(output, b"abcabcabc");
//! ```
//!
//! [RFC 1951]: https://www.rfc-editor.org/rfc/rfc1951

pub mod bitreader;
pub mod decoder;
pub mod error;
pub mod hex;
pub mod huffman;
pub mod tables;

pub use decoder::inflate;
pub use error::{Error, Result};
