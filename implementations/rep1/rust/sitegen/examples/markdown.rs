//! Convert Markdown on stdin to HTML on stdout.
//!
//! Run with `cargo run --release --example markdown < file.md`.

use std::io::{Read, Write};

fn main() {
    let mut input = String::new();
    std::io::stdin()
        .read_to_string(&mut input)
        .expect("stdin must be UTF-8");
    // Deeply nested input recurses deeply, so use a large stack.
    let html = std::thread::Builder::new()
        .stack_size(512 * 1024 * 1024)
        .spawn(move || sitegen::markdown::to_html(&input))
        .unwrap()
        .join()
        .unwrap();
    std::io::stdout().write_all(html.as_bytes()).unwrap();
}
