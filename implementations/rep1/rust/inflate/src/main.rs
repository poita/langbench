//! Command-line front end: reads a hex-encoded raw DEFLATE stream on stdin and
//! prints the decompressed bytes as hex, or `error` if the stream is malformed.

use std::io::{self, Read, Write};

fn main() -> io::Result<()> {
    let mut input = Vec::new();
    io::stdin().lock().read_to_end(&mut input)?;

    let result = inflate::hex::decode(&input)
        .ok()
        .and_then(|bytes| inflate::inflate(&bytes).ok());

    let mut stdout = io::stdout().lock();
    match result {
        Some(data) => writeln!(stdout, "{}", inflate::hex::encode(&data))?,
        None => writeln!(stdout, "error")?,
    }
    stdout.flush()
}
