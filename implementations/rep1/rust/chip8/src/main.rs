//! Command-line front end: reads the input on stdin, writes the report to
//! stdout. See `README.md` for the format.

use std::io::{self, Read, Write};
use std::process::ExitCode;

fn main() -> ExitCode {
    let mut text = String::new();
    if let Err(e) = io::stdin().read_to_string(&mut text) {
        eprintln!("chip8: cannot read stdin: {e}");
        return ExitCode::from(2);
    }
    match chip8::run_text(&text) {
        Ok(out) => {
            let mut stdout = io::stdout().lock();
            if stdout.write_all(out.as_bytes()).and_then(|_| stdout.flush()).is_err() {
                return ExitCode::from(2);
            }
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!("chip8: {e}");
            ExitCode::FAILURE
        }
    }
}
