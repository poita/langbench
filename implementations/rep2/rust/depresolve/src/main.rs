//! Command-line front end: reads a registry and root manifest on stdin and
//! prints the resolution on stdout. See the README for the format.

use std::io::{self, Read, Write};
use std::process::ExitCode;

fn main() -> ExitCode {
    let mut buf = Vec::new();
    if let Err(e) = io::stdin().lock().read_to_end(&mut buf) {
        eprintln!("depresolve: cannot read stdin: {e}");
        return ExitCode::from(2);
    }
    let input = String::from_utf8_lossy(&buf);
    match depresolve::resolve_str(&input) {
        Ok(out) => {
            let mut stdout = io::stdout().lock();
            if stdout.write_all(out.as_bytes()).and_then(|_| stdout.flush()).is_err() {
                return ExitCode::from(2);
            }
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!("depresolve: {e}");
            ExitCode::from(2)
        }
    }
}
