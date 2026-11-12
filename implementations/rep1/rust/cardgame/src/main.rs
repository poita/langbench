//! Command-line front end: reads a match file on stdin, writes the log to
//! stdout. See the README for the format.

use std::io::{Read, Write};

fn main() {
    let mut bytes = Vec::new();
    if std::io::stdin().read_to_end(&mut bytes).is_err() {
        println!("FATAL bad-setup");
        return;
    }
    let input = String::from_utf8_lossy(&bytes);
    let output = cardgame::run_match(&input);
    let stdout = std::io::stdout();
    let mut lock = stdout.lock();
    let _ = lock.write_all(output.as_bytes());
    let _ = lock.flush();
}
