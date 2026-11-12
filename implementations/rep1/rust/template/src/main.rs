//! Command-line front end: reads the whole of stdin, renders the first
//! template and prints the result, or a single `error: <kind>` line.

use std::io::{Read, Write};

/// Rendering is recursive; run it on a thread with a generous stack.
const STACK_SIZE: usize = 1 << 30;

fn run(input: Vec<u8>) -> String {
    let text = String::from_utf8_lossy(&input);
    match template::render_input(&text) {
        Ok(mut out) => {
            out.push('\n');
            out
        }
        Err(e) => {
            eprintln!("{}", e);
            format!("error: {}\n", e.kind())
        }
    }
}

fn main() {
    let mut input = Vec::new();
    if let Err(e) = std::io::stdin().read_to_end(&mut input) {
        eprintln!("cannot read stdin: {}", e);
        std::process::exit(1);
    }
    let output = std::thread::Builder::new()
        .stack_size(STACK_SIZE)
        .spawn(move || run(input))
        .expect("spawn render thread")
        .join()
        .unwrap_or_else(|_| {
            eprintln!("internal error");
            std::process::exit(1);
        });
    let mut stdout = std::io::stdout().lock();
    let _ = stdout.write_all(output.as_bytes());
    let _ = stdout.flush();
}
