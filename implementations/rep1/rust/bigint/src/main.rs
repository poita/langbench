//! Command-line tool: reads queries (`<a> <op> <b>`) from standard input, one
//! per line, and writes one result line per query to standard output.

use std::io::{self, Read, Write};
use std::process::ExitCode;

fn main() -> ExitCode {
    let mut input = String::new();
    if let Err(e) = io::stdin().lock().read_to_string(&mut input) {
        eprintln!("bigint: failed to read standard input: {e}");
        return ExitCode::FAILURE;
    }
    let output = bigint::query::run(&input);
    let mut stdout = io::stdout().lock();
    if let Err(e) = stdout.write_all(output.as_bytes()).and_then(|()| stdout.flush()) {
        eprintln!("bigint: failed to write standard output: {e}");
        return ExitCode::FAILURE;
    }
    ExitCode::SUCCESS
}
