//! # jq-subset
//!
//! An interpreter for a subset of the [jq](https://jqlang.github.io/jq/)
//! filter language, together with its own JSON parser and serializer. It
//! depends on nothing but the standard library.
//!
//! The crate is organised by responsibility:
//!
//! * [`value`] / [`object`]: the immutable, cheaply clonable data model;
//! * [`json`]: JSON text to [`Value`] and back;
//! * [`parser`] (internal) and [`ast`]: filter text to a syntax tree;
//! * [`eval`] and [`builtins`] (internal): the lazy, ordered evaluator.
//!
//! ## Example
//!
//! ```
//! use jq_subset::{Filter, Value};
//!
//! let filter = Filter::parse(".users | map(select(.age >= 30)) | map(.name)").unwrap();
//! let doc = Value::parse_json(
//!     r#"{"users":[{"name":"ann","age":31},{"name":"bob","age":25}]}"#,
//! ).unwrap();
//!
//! let results = filter.collect(&doc).unwrap();
//! assert_eq!(results.len(), 1);
//! assert_eq!(results[0].to_json(), r#"["ann"]"#);
//! ```
//!
//! Results can also be consumed as they are produced with [`Filter::run`];
//! if evaluation fails, everything produced before the error has already
//! been delivered.

pub mod ast;
mod builtins;
pub mod error;
mod eval;
pub mod json;
pub mod object;
mod parser;
pub mod value;

pub use error::{Error, JsonError, ParseError};
pub use object::Object;
pub use value::Value;

use eval::{Env, Flow};

/// A parsed filter, ready to be run against any number of inputs.
#[derive(Debug)]
pub struct Filter {
    expr: ast::Expr,
}

impl Filter {
    /// Parses filter source text.
    pub fn parse(source: &str) -> Result<Filter, ParseError> {
        Ok(Filter { expr: parser::parse(source)? })
    }

    /// Runs the filter on `input`, calling `output` with each result as soon
    /// as it is produced, in order.
    ///
    /// Returns the first uncaught runtime error, if any; results produced
    /// before the error have already been passed to `output`.
    pub fn run<F: FnMut(Value)>(&self, input: &Value, mut output: F) -> Result<(), Error> {
        let r = eval::eval(&self.expr, &Env::default(), input, &mut |v| {
            output(v);
            Ok(())
        });
        match r {
            Ok(()) | Err(Flow::Stop) => Ok(()),
            Err(Flow::Err(e)) => Err(e),
        }
    }

    /// Runs the filter on `input` and collects every result.
    ///
    /// On an uncaught runtime error the partial results are discarded; use
    /// [`Filter::run`] to keep them.
    pub fn collect(&self, input: &Value) -> Result<Vec<Value>, Error> {
        let mut out = Vec::new();
        self.run(input, |v| out.push(v))?;
        Ok(out)
    }
}
