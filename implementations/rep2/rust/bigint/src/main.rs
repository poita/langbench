//! Command-line front end: reads queries from stdin, writes results to stdout.
//! See the crate README for the format.

use std::io::{self, BufWriter};
use std::process::ExitCode;

fn main() -> ExitCode {
    let stdin = io::stdin();
    let stdout = io::stdout();
    let out = BufWriter::with_capacity(1 << 16, stdout.lock());
    match bigint::query::run(stdin.lock(), out) {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("bigint: {e}");
            ExitCode::FAILURE
        }
    }
}
