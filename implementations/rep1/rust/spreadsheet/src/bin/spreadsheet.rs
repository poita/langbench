//! Command-line front end: reads commands from stdin, writes the results of
//! `get` and `dump` to stdout. See the README for the command language.

use std::io::{self, BufWriter, Read, Write};
use std::process::ExitCode;
use std::thread;

fn run() -> io::Result<bool> {
    let mut input = Vec::new();
    io::stdin().lock().read_to_end(&mut input)?;
    let input = String::from_utf8(input).map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
    let stdout = io::stdout();
    let mut out = BufWriter::new(stdout.lock());
    let errors = spreadsheet::run_script(&input, &mut out)?;
    out.flush()?;
    for (line, err) in &errors {
        eprintln!("line {line}: {err}");
    }
    Ok(errors.is_empty())
}

fn main() -> ExitCode {
    // Formulas nest deeply; give the parser and evaluator ample stack.
    let worker = thread::Builder::new().stack_size(256 * 1024 * 1024).spawn(run);
    match worker.map(|h| h.join()) {
        Ok(Ok(Ok(true))) => ExitCode::SUCCESS,
        Ok(Ok(Ok(false))) => ExitCode::from(1),
        Ok(Ok(Err(e))) => {
            eprintln!("error: {e}");
            ExitCode::from(2)
        }
        _ => {
            eprintln!("error: worker thread failed");
            ExitCode::from(2)
        }
    }
}
