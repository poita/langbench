//! Command-line front end: reads a program on stdin, writes one line per
//! declaration on stdout.

use std::io::{self, Read, Write};
use std::process::ExitCode;

fn main() -> ExitCode {
    let mut src = String::new();
    if let Err(e) = io::stdin().read_to_string(&mut src) {
        eprintln!("typeinfer: cannot read stdin: {}", e);
        return ExitCode::from(2);
    }
    match typeinfer::infer_to_string(&src) {
        Ok(out) => {
            let mut stdout = io::stdout().lock();
            if stdout.write_all(out.as_bytes()).and_then(|_| stdout.flush()).is_err() {
                return ExitCode::from(2);
            }
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!("typeinfer: {}", e);
            ExitCode::from(2)
        }
    }
}
