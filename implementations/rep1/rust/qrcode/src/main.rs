//! Command-line tool: reads `<ecl> <mask> <text>` queries from stdin and
//! prints each symbol as a `#`/`.` matrix.

use std::io::{self, Read, Write};
use std::process::ExitCode;

use qrcode::query::parse_line;
use qrcode::QrCode;

fn run() -> Result<(), Box<dyn std::error::Error>> {
    let mut input = Vec::new();
    io::stdin().lock().read_to_end(&mut input)?;
    let stdout = io::stdout();
    let mut out = io::BufWriter::new(stdout.lock());

    for (n, line) in input.split(|&b| b == b'\n').enumerate() {
        let line = line.strip_suffix(b"\r").unwrap_or(line);
        if line.is_empty() {
            continue;
        }
        let q = parse_line(line).map_err(|e| format!("line {}: {e}", n + 1))?;
        let qr =
            QrCode::encode(q.text, q.ecl, q.mask).map_err(|e| format!("line {}: {e}", n + 1))?;
        writeln!(out, "version {} mask {}", qr.version().number(), qr.mask())?;
        out.write_all(qr.to_text().as_bytes())?;
        out.write_all(b"\n")?;
    }
    out.flush()?;
    Ok(())
}

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("qrcode: {e}");
            ExitCode::FAILURE
        }
    }
}
