//! Command-line driver: reads a module stream on stdin, compiles and runs it.

use std::io::{Read, Write};

fn main() {
    let mut input = Vec::new();
    if std::io::stdin().read_to_end(&mut input).is_err() {
        return;
    }
    let text = String::from_utf8_lossy(&input);
    let out = langvm::run_source_to_bytes(&text);
    let stdout = std::io::stdout();
    let mut lock = stdout.lock();
    let _ = lock.write_all(&out);
    let _ = lock.flush();
}
