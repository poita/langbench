//! Command-line tool: reads one operation per line on stdin, writes one
//! 8-digit hex result per line on stdout.

use std::io::{self, BufWriter, Read, Write};
use std::process::ExitCode;

use softfloat::line::{parse_line, push_hex8};

fn run() -> io::Result<()> {
    let mut input = String::new();
    io::stdin().lock().read_to_string(&mut input)?;

    let mut out = String::with_capacity(input.len() / 2 + 16);
    for (n, line) in input.lines().enumerate() {
        let line = line.strip_suffix('\r').unwrap_or(line);
        match parse_line(line) {
            Ok((op, a, b)) => push_hex8(&mut out, op.apply(a, b)),
            Err(e) => {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    format!("line {}: {e}", n + 1),
                ))
            }
        }
        out.push('\n');
    }

    let mut w = BufWriter::new(io::stdout().lock());
    w.write_all(out.as_bytes())?;
    w.flush()
}

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("softfloat: {e}");
            ExitCode::FAILURE
        }
    }
}
