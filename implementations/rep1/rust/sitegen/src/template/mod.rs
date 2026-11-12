//! A Jinja-style template engine.
//!
//! The language is a subset of Jinja2: `{{ expr }}` output, `{% if %}`,
//! `{% for %}` (with `loop.index`, `loop.index0`, `loop.first`, `loop.last`
//! and `loop.length`), `{% set %}`, `{% macro %}`, `{% include %}`,
//! template inheritance with `{% extends %}`, `{% block %}` and `super()`,
//! comments, whitespace control with `-`, and the filters `upper`, `lower`,
//! `trim`, `escape`, `replace`, `length`, `int`, `join`, `first`, `last`,
//! `reverse`, `sort` and `default`.
//!
//! Using an undefined value in any way other than testing it with
//! `is defined` or applying `default` is an error, as with Jinja2's
//! `StrictUndefined`. Autoescaping is off, and there is no automatic
//! trimming of blocks.
//!
//! A template source is used exactly as given: unlike Jinja2's file loader,
//! no trailing newline is removed. Callers that read templates from files
//! and want Jinja2's default behaviour strip one trailing `\n` themselves.
//!
//! ```
//! use sitegen::template::{Dict, Environment, Value};
//!
//! let mut env = Environment::new();
//! env.add_template("hello", "Hello {{ name|upper }}!{% for i in range(n) %} {{ i }}{% endfor %}");
//!
//! let mut ctx = Dict::new();
//! ctx.insert("name", Value::str("world"));
//! ctx.insert("n", Value::Int(3));
//! assert_eq!(env.render("hello", &ctx).unwrap(), "Hello WORLD! 0 1 2");
//! ```

mod ast;
mod error;
mod eval;
mod filters;
mod lexer;
mod ops;
mod parser;
mod value;

use std::cell::RefCell;
use std::collections::HashMap;
use std::rc::Rc;

pub use ast::Template;
pub use error::{Error, ErrorKind};
pub use value::{Dict, Value};

/// A set of named templates that can include and extend each other.
///
/// Templates are parsed lazily, the first time they are needed, and at most
/// once.
#[derive(Default)]
pub struct Environment {
    sources: HashMap<String, String>,
    cache: RefCell<HashMap<String, Rc<Template>>>,
}

impl Environment {
    /// An environment with no templates.
    pub fn new() -> Environment {
        Environment::default()
    }

    /// Register (or replace) a template. The source is not parsed until the
    /// template is first rendered, included or extended.
    pub fn add_template(&mut self, name: impl Into<String>, source: impl Into<String>) {
        let name = name.into();
        self.cache.borrow_mut().remove(&name);
        self.sources.insert(name, source.into());
    }

    /// Whether a template with this name is registered.
    pub fn has_template(&self, name: &str) -> bool {
        self.sources.contains_key(name)
    }

    /// Load (parse and check) a template by name.
    pub(crate) fn load(&self, name: &str) -> Result<Rc<Template>, Error> {
        if let Some(t) = self.cache.borrow().get(name) {
            return Ok(t.clone());
        }
        let src = self.sources.get(name).ok_or_else(|| {
            Error::new(ErrorKind::Template, format!("no template named `{}`", name))
        })?;
        let tpl = Rc::new(parser::parse_template(src)?);
        self.cache
            .borrow_mut()
            .insert(name.to_string(), tpl.clone());
        Ok(tpl)
    }

    /// Render the template `name` with `context` as the variables of the
    /// root scope.
    pub fn render(&self, name: &str, context: &Dict) -> Result<String, Error> {
        let tpl = self.load(name)?;
        let root = eval::Scope::with_vars(context.clone());
        eval::Interp::new(self).render_main(&tpl, root)
    }
}

#[cfg(test)]
mod tests;
