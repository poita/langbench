//! Command-line front end: reads `<DTSTART> <RRULE> <N>` lines on stdin and
//! prints the first N occurrences of each rule, one line per input line.

use std::io::{self, Read, Write};
use std::process::ExitCode;

use rrule::Request;

fn run() -> Result<(), String> {
    let mut input = String::new();
    io::stdin().read_to_string(&mut input).map_err(|e| format!("reading stdin: {e}"))?;
    let stdout = io::stdout();
    let mut out = io::BufWriter::new(stdout.lock());
    for (i, line) in input.lines().enumerate() {
        let request = Request::parse(line).map_err(|e| format!("line {}: {e}", i + 1))?;
        let mut text = request.render();
        text.push('\n');
        out.write_all(text.as_bytes()).map_err(|e| format!("writing stdout: {e}"))?;
    }
    out.flush().map_err(|e| format!("writing stdout: {e}"))
}

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(msg) => {
            eprintln!("rrule: {msg}");
            ExitCode::FAILURE
        }
    }
}
