//! # template
//!
//! A small Jinja2-style template engine: expressions, filters, `if`/`for`,
//! `set`, macros, `include`, template inheritance (`extends`/`block`/
//! `super()`), comments and whitespace control.
//!
//! The crate is organised by responsibility:
//!
//! * [`input`] splits the command-line framing (JSON context + named
//!   templates);
//! * [`json`] parses the JSON context into [`Value`]s;
//! * `lexer` and [`parser`] turn template source into a syntax tree
//!   ([`ast`]);
//! * [`engine`] interprets the tree against a [`scope`] chain;
//! * [`value`], [`ops`] and [`filters`] hold the runtime semantics.
//!
//! # Example
//!
//! ```
//! use template::{json, Engine};
//!
//! let context = json::parse(r#"{"user": {"name": "Ada"}, "items": [3, 1, 2]}"#).unwrap();
//! let engine = Engine::new(
//!     context,
//!     [("page".to_string(), "Hi {{ user.name|upper }}: {{ items|sort|join(',') }}".to_string())],
//! )
//! .unwrap();
//! assert_eq!(engine.render("page").unwrap(), "Hi ADA: 1,2,3");
//! ```
//!
//! Or drive the whole stdin protocol at once:
//!
//! ```
//! let out = template::render_input("{\"n\": 2}\n--\n=== main\n{{ n * 21 }}").unwrap();
//! assert_eq!(out, "42");
//! ```

pub mod ast;
pub mod engine;
pub mod error;
pub mod filters;
pub mod input;
pub mod json;
mod lexer;
pub mod ops;
pub mod parser;
pub mod scope;
pub mod value;

pub use engine::Engine;
pub use error::{Error, ErrorKind, Result};
pub use value::{Dict, Value};

/// Renders the first template of a complete program input (JSON context,
/// `--` line, `=== name` templates) and returns the rendered text.
pub fn render_input(text: &str) -> Result<String> {
    let input = input::split(text)?;
    let main = input.templates[0].0.clone();
    let context = json::parse(&input.context)?;
    let engine = Engine::new(context, input.templates)?;
    engine.render(&main)
}
