//! Command-line front end: reads a schema and requests from stdin, writes one
//! result line per request to stdout. See the README for the format.

use std::io::{Read, Write};

/// Nesting is bounded by the input format, but run on a roomy stack anyway.
const STACK_SIZE: usize = 256 * 1024 * 1024;

fn run() {
    let mut input = Vec::new();
    if std::io::stdin().lock().read_to_end(&mut input).is_err() {
        return;
    }
    let output = protowire::session::run(&input);
    let mut stdout = std::io::stdout().lock();
    let _ = stdout.write_all(&output);
    let _ = stdout.flush();
}

fn main() {
    // The exit status is always 0 by contract; a malformed request is a
    // normal `error` line, not a failure of the tool.
    if let Ok(worker) = std::thread::Builder::new().stack_size(STACK_SIZE).spawn(run) {
        let _ = worker.join();
    } else {
        run();
    }
}
