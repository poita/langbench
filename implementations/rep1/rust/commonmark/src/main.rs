//! Command-line front end: reads Markdown on stdin, writes HTML on stdout.

use std::io::{self, Read, Write};
use std::process::ExitCode;

fn run() -> io::Result<()> {
    let mut input = Vec::new();
    io::stdin().lock().read_to_end(&mut input)?;
    let text = String::from_utf8_lossy(&input);
    let html = commonmark::to_html(&text);
    let mut out = io::stdout().lock();
    out.write_all(html.as_bytes())?;
    out.flush()
}

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("commonmark: {e}");
            ExitCode::FAILURE
        }
    }
}
