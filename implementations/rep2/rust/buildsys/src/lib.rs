//! # Kiln
//!
//! Kiln is a deterministic, incremental build system simulator. It reads a
//! *workspace* of build files written in the **Kiln Build Language** (KBL) and
//! ordinary source files, evaluates the build files into a graph of build
//! steps, and executes the out-of-date steps on simulated parallel workers
//! against a virtual file system. Nothing is ever run by a real shell: the
//! sixteen built-in commands are implemented by the engine, and every command
//! has an integer cost that drives a fully deterministic scheduling
//! simulation.
//!
//! ## Layout
//!
//! | Module | Responsibility |
//! |--------|----------------|
//! | [`workspace`] | the virtual file system, content hashes, glob index |
//! | [`hash`] | 64-bit FNV-1a |
//! | [`parser`], [`ast`] | KBL text to syntax trees (the lexer is internal) |
//! | [`value`], [`glob`] | values and the glob matcher (the 39 built-in functions are internal) |
//! | [`step`] | steps and phony targets, and step validation (the interpreter is internal) |
//! | [`command`] | the sixteen commands and their canonical rendering |
//! | [`state`] | the `.kiln-state` file and freshness decisions |
//! | [`engine`] | one complete build: evaluate, validate, schedule, persist state |
//! | [`session`] | scripted sessions and the log |
//!
//! Graph construction and the worker simulation are internal modules; their
//! results surface through [`BuildReport`] and [`Event`].
//!
//! ## Example
//!
//! ```
//! use kiln::{Session, Workspace};
//!
//! let mut ws = Workspace::new();
//! ws.write("main.kiln", b"step {\n    out \"out/hello.txt\"\n    cmd write(\"hello\\n\")\n}\ndefault \"out/hello.txt\"\n".to_vec());
//!
//! let session = Session::parse(b"build\nbuild\n").unwrap();
//! let log = String::from_utf8(session.run(&mut ws)).unwrap();
//!
//! assert_eq!(log, "\
//! step 1: build (default) -j 1
//!   run 0 1 w0 out/hello.txt write(\"hello\\n\")
//!   ok ran=1 hit=0 time=1
//! step 2: build (default) -j 1
//!   hit 0 out/hello.txt
//!   ok ran=0 hit=1 time=0
//! ");
//! assert_eq!(ws.read("out/hello.txt"), Some(&b"hello\n"[..]));
//! ```

#![warn(missing_docs)]

pub mod ast;
pub mod engine;
mod builtins;
pub mod command;
pub mod error;
mod eval;
pub mod glob;
mod graph;
pub mod hash;
mod lexer;
pub mod parser;
mod scheduler;
pub mod session;
pub mod state;
pub mod step;
pub mod value;
pub mod workspace;

pub use engine::{build, BuildReport, Summary};
pub use scheduler::{Event, EventKind};
pub use error::{Error, ErrorKind};
pub use session::{Session, SessionStep};
pub use workspace::Workspace;
