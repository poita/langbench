//! # tomlcodec
//!
//! A from-scratch TOML 1.0.0 parser and canonical serializer, built on the
//! standard library only, with a *tagged JSON* interchange format (the one
//! used by the `toml-test` suite).
//!
//! ```
//! use tomlcodec::{parse, tagged_json, to_toml};
//!
//! let doc = parse("name = \"Tom\"\n[db]\nports = [8001, 8002]\n").unwrap();
//! assert_eq!(doc.get("name").and_then(|v| v.as_str()), Some("Tom"));
//!
//! // Tagged JSON: compact, key-sorted, every scalar as {"type", "value"}.
//! let json = tagged_json::to_string(&doc);
//! assert!(json.starts_with("{\"db\":"));
//!
//! // Canonical TOML, and back.
//! let toml = to_toml(&doc).unwrap();
//! assert_eq!(parse(&toml).unwrap(), doc);
//! ```
//!
//! ## Data model
//!
//! A document is a [`Value`] tree: tables ([`Table`], a sorted map), arrays,
//! and [`Scalar`]s. Scalars keep their *canonical text*: integers in decimal,
//! floats as 17 significant digits in scientific notation (`%.16e`), date-times
//! as RFC 3339 text with an uppercase `T`, trimmed fractional seconds and `Z`
//! for UTC. Nothing is converted to native numbers or dates and back.
//!
//! ## Modules
//!
//! * [`value`] — the data model.
//! * [`tagged_json`] — reading and writing tagged JSON.
//! * [`encoder`] — canonical TOML output.
//! * [`protocol`] — the stdin/stdout protocol of the CLI.
//! * [`error`] — error types.
//!
//! Internally the parser, the table-definition rules, number and date-time
//! handling live in private modules.

mod datetime;
pub mod encoder;
pub mod error;
mod number;
mod parser;
pub mod protocol;
mod tables;
pub mod tagged_json;
pub mod value;

pub use encoder::to_toml;
pub use error::{ParseError, TaggedError};
pub use value::{Scalar, ScalarKind, Table, Value};

/// Parses a TOML 1.0.0 document. The returned value is always a
/// [`Value::Table`].
pub fn parse(input: &str) -> Result<Value, ParseError> {
    parser::parse_bytes(input.as_bytes())
}

/// Like [`parse`], for raw bytes: input that is not valid UTF-8 is rejected.
pub fn parse_bytes(input: &[u8]) -> Result<Value, ParseError> {
    parser::parse_bytes(input)
}
