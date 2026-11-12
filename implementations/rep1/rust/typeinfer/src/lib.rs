//! # typeinfer
//!
//! Hindley-Milner type inference (Algorithm J, with Rémy-style levels) for a
//! small ML-like language: integers, booleans, unit, functions, tuples, lists,
//! `let` / `let rec` with full let-polymorphism (no value restriction), and a
//! handful of built-in functions (`map`, `fold`, `fst`, ...).
//!
//! A program is a sequence of `;;`-terminated declarations. Each is
//! type-checked in order; a failing declaration reports an error
//! ([`TypeError`]) and adds nothing to the environment.
//!
//! ```
//! let out = typeinfer::infer_to_string(
//!     "let compose f g x = f (g x);;\n\
//!      let rec len l = if null l then 0 else 1 + len (tl l);;\n\
//!      fun f -> (f 1, f true);;\n",
//! ).unwrap();
//! assert_eq!(
//!     out,
//!     "compose : ('a -> 'b) -> ('c -> 'a) -> 'c -> 'b\n\
//!      len : 'a list -> int\n\
//!      error: unify\n"
//! );
//! ```
//!
//! For finer control use a [`Session`], which keeps the top-level environment
//! between calls:
//!
//! ```
//! use typeinfer::{Session, TypeError};
//!
//! let mut s = Session::new();
//! let r = s.infer_source("let id = fun x -> x;; id 1;; undefined;;").unwrap();
//! assert_eq!(r[0].to_string(), "id : 'a -> 'a");
//! assert_eq!(r[1].outcome, Ok("int".to_string()));
//! assert_eq!(r[2].outcome, Err(TypeError::Unbound));
//! ```
//!
//! ## Design
//!
//! * [`lexer`] / [`parser`] / [`ast`]: source text to syntax tree.
//! * [`types`]: the type graph (a shared DAG in an arena), union-find
//!   unification with an occurs check, level-based generalisation, and
//!   instantiation. Every walk is linear in the number of distinct nodes.
//! * [`pretty`]: rendering types (variables named by first appearance).
//! * [`infer`] (private) and [`Session`]: the inference pass and the
//!   top-level driver.
//!
//! Inference and parsing recurse on expression depth, so the source-level
//! entry points ([`Session::infer_source`], [`infer_program`],
//! [`infer_to_string`]) run on a helper thread with a large stack.

pub mod ast;
mod env;
mod error;
mod infer;
pub mod lexer;
pub mod parser;
mod pretty;
mod session;
mod symbol;
pub mod types;

pub use error::{ParseError, TypeError};
pub use session::{infer_program, infer_to_string, DeclResult, Session};
pub use symbol::{Interner, Sym};
