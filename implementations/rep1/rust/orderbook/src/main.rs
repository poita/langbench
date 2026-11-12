//! Command-line front end: reads a command stream on stdin and prints the
//! resulting events on stdout.

use std::io::{self, Read};
use std::process::ExitCode;

fn main() -> ExitCode {
    let mut raw = Vec::new();
    if let Err(e) = io::stdin().lock().read_to_end(&mut raw) {
        eprintln!("orderbook: cannot read stdin: {e}");
        return ExitCode::FAILURE;
    }
    let input = match std::str::from_utf8(&raw) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("orderbook: input is not valid UTF-8: {e}");
            return ExitCode::FAILURE;
        }
    };
    match orderbook::process(input, io::stdout().lock()) {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("orderbook: {e}");
            ExitCode::FAILURE
        }
    }
}
