//! # json-canon
//!
//! A strict [RFC 8259](https://www.rfc-editor.org/rfc/rfc8259) JSON parser and
//! canonical serializer, written from scratch with no dependencies.
//!
//! The canonical form has no insignificant whitespace, object members sorted by
//! key in UTF-16 code-unit order with duplicate keys collapsed (last value
//! wins), minimal string escaping, and numbers echoed textually (never
//! converted to floating point) with only the exponent normalized.
//!
//! ```
//! let out = json_canon::canonicalize(r#"{ "b": [1, 2.50, 1E+3], "a": "héllo\/", "b": null }"#.as_bytes()).unwrap();
//! assert_eq!(out, r#"{"a":"héllo/","b":null}"#);
//! assert!(json_canon::canonicalize(b"[1, 2, ]").is_err());
//! ```
//!
//! # Modules
//!
//! * [`utf8`]: strict UTF-8 validation.
//! * [`parser`]: recursive-descent parser producing a [`Value`] tree.
//! * [`serializer`]: canonical output, including UTF-16 key ordering.
//! * [`value`]: the document tree type.
//! * [`error`]: the error type.

pub mod error;
pub mod parser;
pub mod serializer;
pub mod utf8;
pub mod value;

pub use error::{Error, ErrorKind};
pub use parser::{parse, MAX_DEPTH};
pub use serializer::{to_canonical_string, write_canonical};
pub use value::Value;

/// Parses `input` as a complete JSON document and returns its canonical
/// serialization (without a trailing newline).
pub fn canonicalize(input: &[u8]) -> Result<String, Error> {
    Ok(to_canonical_string(&parse(input)?))
}
