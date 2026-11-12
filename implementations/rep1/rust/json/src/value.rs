//! The in-memory document tree.

/// A parsed JSON value.
///
/// Numbers are kept as their (already normalized) text so that integers of any
/// size and any number of fractional digits survive unchanged. Objects keep
/// every member, duplicates included, in input order; deduplication and
/// ordering happen at serialization time.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Value {
    /// `null`
    Null,
    /// `true` or `false`
    Bool(bool),
    /// A number in canonical textual form (see [`crate::parser`]).
    Number(String),
    /// A decoded string.
    String(String),
    /// Elements in input order.
    Array(Vec<Value>),
    /// Members `(decoded key, value)` in input order, duplicates included.
    Object(Vec<(String, Value)>),
}
