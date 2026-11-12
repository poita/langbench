//! Command-line front end: reads a command stream on stdin and writes the
//! results to stdout. See `webhooks::protocol` for the command set.

use std::io::{self, Read, Write};

fn main() {
    let mut input = Vec::new();
    // Unreadable stdin is treated as whatever was read so far.
    let _ = io::stdin().lock().read_to_end(&mut input);
    let output = webhooks::run_commands(&input);
    let mut stdout = io::stdout().lock();
    let _ = stdout.write_all(output.as_bytes());
    let _ = stdout.flush();
}
