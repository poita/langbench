//! Command-line front end: reads a SQL script on stdin, executes it, and
//! prints each `SELECT`'s result (or `error`) on stdout.

use std::io::{self, Read, Write};
use std::thread;

use minisql::Database;

fn run() -> io::Result<()> {
    let mut input = Vec::new();
    io::stdin().lock().read_to_end(&mut input)?;
    let script = String::from_utf8_lossy(&input);

    let stdout = io::stdout();
    let mut out = io::BufWriter::new(stdout.lock());
    Database::new().run_script_to(&script, &mut out)?;
    out.flush()
}

fn main() {
    // Deeply nested expressions recurse deeply; give the work a big stack.
    let worker = thread::Builder::new()
        .stack_size(512 * 1024 * 1024)
        .spawn(run)
        .expect("failed to spawn worker thread");
    match worker.join() {
        Ok(Ok(())) => {}
        Ok(Err(e)) if e.kind() == io::ErrorKind::BrokenPipe => {}
        Ok(Err(e)) => {
            eprintln!("minisql: {e}");
            std::process::exit(1);
        }
        Err(_) => std::process::exit(101),
    }
}
