//! Command-line tool: `tomlcodec`.
//!
//! Reads a mode line (`decode` or `encode`) and a document from stdin and
//! writes the result to stdout. See the README for details.

use std::io::{Read, Write};
use std::process::ExitCode;

fn main() -> ExitCode {
    let mut input = Vec::new();
    if let Err(e) = std::io::stdin().lock().read_to_end(&mut input) {
        eprintln!("tomlcodec: cannot read stdin: {e}");
        return ExitCode::from(2);
    }
    // Deeply nested documents recurse deeply; run on a thread with a roomy stack.
    let worker = std::thread::Builder::new()
        .stack_size(256 * 1024 * 1024)
        .spawn(move || tomlcodec::protocol::process(&input));
    let result = match worker.map(|h| h.join()) {
        Ok(Ok(r)) => r,
        _ => {
            eprintln!("tomlcodec: internal failure");
            return ExitCode::from(2);
        }
    };
    match result {
        Ok(out) => {
            let mut stdout = std::io::stdout().lock();
            if stdout.write_all(&out).and_then(|_| stdout.flush()).is_err() {
                return ExitCode::from(2);
            }
            ExitCode::SUCCESS
        }
        Err(msg) => {
            eprintln!("tomlcodec: {msg}");
            ExitCode::from(2)
        }
    }
}
