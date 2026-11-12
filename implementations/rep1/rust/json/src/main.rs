//! Command-line tool: reads a JSON document on stdin and prints its canonical
//! serialization, or `invalid` if the document is not valid. Always exits 0
//! unless stdin cannot be read.

use std::io::{self, Read, Write};
use std::process::ExitCode;

fn run() -> io::Result<()> {
    let mut input = Vec::new();
    io::stdin().lock().read_to_end(&mut input)?;
    let mut out = match json_canon::canonicalize(&input) {
        Ok(s) => s,
        Err(_) => String::from("invalid"),
    };
    out.push('\n');
    let mut stdout = io::stdout().lock();
    stdout.write_all(out.as_bytes())?;
    stdout.flush()
}

fn main() -> ExitCode {
    // Run on a thread with a generous stack so recursion to the maximum
    // nesting depth is safe regardless of the platform's main-thread stack.
    let handle = std::thread::Builder::new()
        .stack_size(256 * 1024 * 1024)
        .spawn(run);
    match handle.map(|h| h.join()) {
        Ok(Ok(Ok(()))) => ExitCode::SUCCESS,
        Ok(Ok(Err(e))) => {
            eprintln!("json-canon: {e}");
            ExitCode::FAILURE
        }
        _ => {
            eprintln!("json-canon: internal error");
            ExitCode::FAILURE
        }
    }
}
