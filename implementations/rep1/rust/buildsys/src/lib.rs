//! # buildsys — Kiln, an incremental build system
//!
//! Kiln reads a *workspace* of build files written in the Kiln Build Language
//! (KBL) and ordinary source files, evaluates the build files into a graph of
//! steps, and executes the out-of-date steps on a simulated set of parallel
//! workers against a virtual file system. Nothing runs in a real shell: the
//! sixteen built-in commands are implemented here, and every command has an
//! integer *cost* that drives a deterministic scheduling simulation.
//!
//! ## Modules
//!
//! | Module | Responsibility |
//! |--------|----------------|
//! | [`workspace`] | the virtual file system, path rules, `glob` index |
//! | [`hash`] | 64-bit FNV-1a |
//! | [`glob`] | glob pattern compilation and matching |
//! | [`lexer`], [`parser`], [`ast`] | KBL text to syntax trees |
//! | [`value`], [`builtins`], [`eval`] | values, the 39 functions, the interpreter |
//! | [`step`], [`command`] | steps, validation and the sixteen commands |
//! | [`graph`] | resolution, validation, cycle detection, reachability |
//! | [`state`] | the `.kiln-state` file and change detection |
//! | [`build`] | one build: configuration, scheduler, state update |
//! | [`session`] | session scripts and the log |
//!
//! ## Example
//!
//! ```
//! use buildsys::{parse_session, run_session, Workspace};
//!
//! let mut ws = Workspace::new();
//! ws.write(b"main.kiln", b"step {\n    out \"out/hello.txt\"\n    cmd write(\"hello\\n\")\n}\ndefault \"out/hello.txt\"\n".to_vec());
//!
//! let session = parse_session(b"build\nbuild\n");
//! let log = run_session(&mut ws, &session);
//! assert_eq!(
//!     String::from_utf8(log).unwrap(),
//!     "step 1: build (default) -j 1\n  run 0 1 w0 out/hello.txt write(\"hello\\n\")\n  ok ran=1 hit=0 time=1\n\
//!      step 2: build (default) -j 1\n  hit 0 out/hello.txt\n  ok ran=0 hit=1 time=0\n"
//! );
//! assert_eq!(ws.get(b"out/hello.txt").unwrap().content.as_slice(), b"hello\n");
//! ```
//!
//! A single build can also be driven directly with [`build::build`], which
//! returns the events and the summary (or the error) without any log
//! formatting.

pub mod ast;
pub mod build;
pub mod builtins;
pub mod command;
pub mod error;
pub mod eval;
pub mod glob;
pub mod graph;
pub mod hash;
pub mod lexer;
pub mod parser;
pub mod session;
pub mod state;
pub mod step;
pub mod value;
pub mod workspace;

pub use build::{build, BuildReport, Event, EventKind, Summary};
pub use error::{Error, ErrorKind};
pub use session::{parse_session, run_session, SessionStep};
pub use workspace::Workspace;

use std::io;
use std::path::Path;

/// Runs the session in `input/session.txt` against the workspace formed by
/// the rest of `input`, writing `log.txt` and `workspace/` into `output`.
pub fn run_directory(input: &Path, output: &Path) -> io::Result<()> {
    let mut ws = Workspace::load_dir(input)?;
    let script = std::fs::read(input.join("session.txt"))?;
    let steps = parse_session(&script);
    let log = run_session(&mut ws, &steps);
    std::fs::create_dir_all(output)?;
    std::fs::write(output.join("log.txt"), log)?;
    ws.write_dir(&output.join("workspace"))
}
