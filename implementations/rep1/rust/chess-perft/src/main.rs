//! Command-line front end: reads perft/divide queries from stdin, one per
//! line, and writes the results to stdout. See the README for the format.

use std::io::{self, Read, Write};
use std::process::ExitCode;

fn main() -> ExitCode {
    let mut input = String::new();
    if let Err(e) = io::stdin().read_to_string(&mut input) {
        eprintln!("chess-perft: cannot read stdin: {e}");
        return ExitCode::FAILURE;
    }
    match chess_perft::query::run(&input) {
        Ok(output) => {
            let mut stdout = io::stdout().lock();
            if stdout.write_all(output.as_bytes()).and_then(|_| stdout.flush()).is_err() {
                return ExitCode::FAILURE;
            }
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!("chess-perft: {e}");
            ExitCode::FAILURE
        }
    }
}
