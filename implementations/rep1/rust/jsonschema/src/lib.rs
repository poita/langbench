//! A from-scratch validator for [JSON Schema] draft 2020-12.
//!
//! The crate is dependency-free and implements everything itself: a JSON
//! parser ([`json`]), exact decimal arithmetic ([`number`]), a regular
//! expression engine for `pattern` ([`regex`]), RFC 3986 reference
//! resolution ([`uri`]), and the schema compiler and evaluator
//! ([`Schema`]).
//!
//! # Example
//!
//! ```
//! use jsonschema::{json, Schema};
//!
//! let schema = json::parse(r#"{
//!     "type": "object",
//!     "properties": {"id": {"type": "integer", "minimum": 1}},
//!     "required": ["id"]
//! }"#).unwrap();
//! let schema = Schema::compile(&schema).unwrap();
//!
//! assert!(schema.is_valid(&json::parse(r#"{"id": 7}"#).unwrap()));
//! assert!(!schema.is_valid(&json::parse(r#"{"id": 0}"#).unwrap()));
//! assert!(!schema.is_valid(&json::parse(r#"{}"#).unwrap()));
//! ```
//!
//! # Semantics
//!
//! * Numbers are exact decimals: `0.3` is a multiple of `0.0001`, and
//!   `1e309` is just a large number.
//! * `format`, `$vocabulary`, `contentEncoding` and friends are annotations
//!   only; they never reject.
//! * Regular expressions follow ECMA-262 (`\b` is ASCII, `$` matches only at
//!   the very end) for the subset documented on [`regex`].
//! * Deeply nested schemas recurse deeply; run validation on a thread with a
//!   large stack if you expect hundreds of levels of nesting.
//!
//! [JSON Schema]: https://json-schema.org/draft/2020-12/json-schema-core

mod bigint;
mod eval;
pub mod json;
pub mod number;
pub mod regex;
mod schema;
pub mod uri;

pub use json::Json;
pub use number::Number;
pub use schema::{Error, Schema, SchemaBuilder};
