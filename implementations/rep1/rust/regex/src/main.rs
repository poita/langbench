//! Command-line front end: reads a batch from stdin, writes results to stdout.

use std::io::{self, Read};
use std::process::ExitCode;

fn main() -> ExitCode {
    let mut input = Vec::new();
    if let Err(e) = io::stdin().lock().read_to_end(&mut input) {
        eprintln!("btregex: cannot read stdin: {e}");
        return ExitCode::from(2);
    }
    let stdout = io::stdout();
    match btregex::batch::run(&input, &mut stdout.lock()) {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("btregex: {e}");
            ExitCode::FAILURE
        }
    }
}
