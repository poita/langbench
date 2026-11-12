//! A small Scheme interpreter with arbitrary-precision integers and proper
//! tail calls.
//!
//! The crate is organised by responsibility:
//!
//! * [`reader`] turns program text into datums ([`Value`]s);
//! * [`analyze`] turns each datum, once, into a tree of [`analyze::Node`]s;
//! * [`eval`] contains the trampolined [`Interpreter`];
//! * [`primitives`] and [`numeric`] implement the built-in procedures;
//! * [`bigint`] is a from-scratch arbitrary-precision integer;
//! * [`printer`] renders values in *write* and *display* form;
//! * [`env`] holds environment frames.
//!
//! # Example
//!
//! ```
//! let output = scheme::run_to_string(
//!     "(define (fact n) (if (= n 0) 1 (* n (fact (- n 1)))))
//!      (fact 25)
//!      (display \"done\")",
//! );
//! assert_eq!(output, "15511210043330985984000000\ndone");
//! ```
//!
//! Values are reference counted and symbols are interned per thread, so an
//! [`Interpreter`] and its values are not `Send`. Deeply non-tail-recursive
//! Scheme programs recurse on the host stack; run them on a thread with a
//! large stack (as the bundled command-line tool does).

pub mod analyze;
pub mod bigint;
pub mod env;
pub mod error;
pub mod eval;
pub mod primitives;
pub mod printer;
pub mod reader;
pub mod value;

mod numeric;

pub use bigint::BigInt;
pub use error::{Error, Result};
pub use eval::Interpreter;
pub use value::{Symbol, Value};

use std::io::{self, Write};

/// Runs a whole program, following the command-line contract: the printed
/// value of every non-void top-level form and all `display` output go to
/// `out`; a runtime error appends `error: <category>` and a newline directly
/// to the output and stops evaluation.
///
/// Returns an error only if writing to `out` failed.
pub fn run_program<W: Write>(src: &str, out: W) -> io::Result<()> {
    let mut interp = Interpreter::new(out);
    if let Err(e) = interp.run(src) {
        interp.write_str(&format!("error: {}\n", e.category()));
    }
    interp.flush()
}

/// Runs a whole program (see [`run_program`]) and returns its output as a string.
pub fn run_to_string(src: &str) -> String {
    let mut buf = Vec::new();
    run_program(src, &mut buf).expect("writing to a Vec cannot fail");
    String::from_utf8_lossy(&buf).into_owned()
}
