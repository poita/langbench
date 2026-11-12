//! The in-memory data model shared by the decoder, the encoder and the
//! tagged-JSON reader and writer.

use std::collections::BTreeMap;

/// A TOML table: keys mapped to values.
///
/// A `BTreeMap<String, _>` iterates in byte order of the UTF-8 keys, which is
/// the same as Unicode code point order — exactly the order the canonical
/// output formats require.
pub type Table = BTreeMap<String, Value>;

/// The type of a [`Scalar`], using the names of the tagged-JSON format.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ScalarKind {
    String,
    Integer,
    Float,
    Bool,
    /// Offset date-time, e.g. `1979-05-27T07:32:00Z`.
    DateTime,
    /// Local date-time, e.g. `1979-05-27T07:32:00`.
    DateTimeLocal,
    /// Local date, e.g. `1979-05-27`.
    DateLocal,
    /// Local time, e.g. `07:32:00`.
    TimeLocal,
}

impl ScalarKind {
    /// The tag used for this type in tagged JSON (`"string"`, `"datetime-local"`, …).
    pub fn tag(self) -> &'static str {
        match self {
            ScalarKind::String => "string",
            ScalarKind::Integer => "integer",
            ScalarKind::Float => "float",
            ScalarKind::Bool => "bool",
            ScalarKind::DateTime => "datetime",
            ScalarKind::DateTimeLocal => "datetime-local",
            ScalarKind::DateLocal => "date-local",
            ScalarKind::TimeLocal => "time-local",
        }
    }

    /// The inverse of [`ScalarKind::tag`].
    pub fn from_tag(tag: &str) -> Option<ScalarKind> {
        Some(match tag {
            "string" => ScalarKind::String,
            "integer" => ScalarKind::Integer,
            "float" => ScalarKind::Float,
            "bool" => ScalarKind::Bool,
            "datetime" => ScalarKind::DateTime,
            "datetime-local" => ScalarKind::DateTimeLocal,
            "date-local" => ScalarKind::DateLocal,
            "time-local" => ScalarKind::TimeLocal,
            _ => return None,
        })
    }
}

/// A scalar value, stored as its canonical text.
///
/// Numbers and dates are never converted to native types and back: the text is
/// the source of truth (see the crate documentation for the text forms).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Scalar {
    /// What kind of scalar this is.
    pub kind: ScalarKind,
    /// The canonical text of the value.
    pub text: String,
}

impl Scalar {
    /// Creates a scalar from a kind and its canonical text.
    pub fn new(kind: ScalarKind, text: impl Into<String>) -> Self {
        Scalar {
            kind,
            text: text.into(),
        }
    }
}

/// A node of a TOML document tree.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Value {
    /// A table (the root of a document is always one).
    Table(Table),
    /// An array (including arrays of tables).
    Array(Vec<Value>),
    /// A scalar.
    Scalar(Scalar),
}

impl Value {
    /// Shorthand for a string scalar.
    pub fn string(s: impl Into<String>) -> Value {
        Value::Scalar(Scalar::new(ScalarKind::String, s))
    }

    /// Shorthand for an integer scalar.
    pub fn integer(i: i64) -> Value {
        Value::Scalar(Scalar::new(ScalarKind::Integer, i.to_string()))
    }

    /// Shorthand for a boolean scalar.
    pub fn boolean(b: bool) -> Value {
        Value::Scalar(Scalar::new(ScalarKind::Bool, if b { "true" } else { "false" }))
    }

    /// The table, if this value is one.
    pub fn as_table(&self) -> Option<&Table> {
        match self {
            Value::Table(t) => Some(t),
            _ => None,
        }
    }

    /// The array elements, if this value is an array.
    pub fn as_array(&self) -> Option<&[Value]> {
        match self {
            Value::Array(a) => Some(a),
            _ => None,
        }
    }

    /// The scalar, if this value is one.
    pub fn as_scalar(&self) -> Option<&Scalar> {
        match self {
            Value::Scalar(s) => Some(s),
            _ => None,
        }
    }

    /// The string contents, if this value is a string scalar.
    pub fn as_str(&self) -> Option<&str> {
        match self {
            Value::Scalar(Scalar {
                kind: ScalarKind::String,
                text,
            }) => Some(text),
            _ => None,
        }
    }

    /// Looks up `key` if this value is a table.
    pub fn get(&self, key: &str) -> Option<&Value> {
        self.as_table()?.get(key)
    }
}
