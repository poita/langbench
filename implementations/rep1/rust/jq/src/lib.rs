//! # jqlite
//!
//! An interpreter for a subset of the [jq](https://jqlang.github.io/jq/) filter language
//! (semantics of jq 1.7), written with only the standard library: its own JSON parser,
//! JSON serializer, filter parser and evaluator.
//!
//! ```
//! use jqlite::{Filter, Value};
//!
//! let filter = Filter::parse(".users | map(select(.age >= 30) | .name)").unwrap();
//! let doc = Value::from_json(r#"{"users":[{"name":"ann","age":31},{"name":"bob","age":25}]}"#).unwrap();
//! let results = filter.collect(&doc).unwrap();
//! assert_eq!(results[0].to_string(), r#"["ann"]"#);
//! ```
//!
//! ## Modules
//!
//! * [`value`] — the immutable, reference-counted [`Value`] type and its total order.
//! * [`object`] — [`Object`], an insertion-ordered map with O(1) lookup.
//! * [`json`] — JSON parsing and compact serialization.
//! * [`error`] — the [`Error`] type.
//!
//! Filters are parsed once into a syntax tree ([`Filter::parse`]) and evaluated lazily by a
//! tree-walking interpreter ([`Filter::run`]), which delivers each output as soon as it is
//! produced.

mod ast;
mod builtins;
pub mod error;
mod eval;
pub mod json;
mod lexer;
pub mod object;
mod ops;
mod parser;
pub mod value;

pub use error::{Error, ErrorKind};
pub use object::Object;
pub use value::Value;

/// A parsed filter, ready to be run against any number of input values.
#[derive(Debug, Clone)]
pub struct Filter {
    expr: ast::Expr,
}

impl Filter {
    /// Parses filter source text.
    pub fn parse(source: &str) -> Result<Filter, Error> {
        Ok(Filter { expr: parser::parse(source)? })
    }

    /// Runs the filter on `input`, calling `sink` with each output in order as it is produced.
    ///
    /// Returns the runtime error that stopped evaluation, if any; outputs delivered before
    /// the error have already been passed to `sink`.
    pub fn run<F: FnMut(Value)>(&self, input: &Value, mut sink: F) -> Result<(), Error> {
        eval::eval(&self.expr, &eval::Env::new(), input, &mut |v| {
            sink(v);
            Ok(())
        })
    }

    /// Runs the filter and gathers all outputs; fails with the first uncaught error.
    pub fn collect(&self, input: &Value) -> Result<Vec<Value>, Error> {
        let mut out = Vec::new();
        self.run(input, |v| out.push(v))?;
        Ok(out)
    }
}

impl Value {
    /// Parses a JSON document.
    pub fn from_json(text: &str) -> Result<Value, Error> {
        json::parse(text)
    }
}

/// Parses `filter` and `document` and returns every output as compact JSON text, together with
/// the error that ended evaluation, if one occurred.
pub fn run_str(filter: &str, document: &str) -> Result<(Vec<String>, Option<Error>), Error> {
    let filter = Filter::parse(filter)?;
    let doc = Value::from_json(document)?;
    let mut lines = Vec::new();
    let err = filter.run(&doc, |v| lines.push(v.to_string())).err();
    Ok((lines, err))
}
