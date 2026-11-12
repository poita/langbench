//! Command-line front end: reads a request on stdin, writes the response to
//! stdout. See the README for the format.

use std::io::{self, BufWriter, Read, Write};
use std::process::ExitCode;

fn main() -> ExitCode {
    let mut input = Vec::new();
    if let Err(e) = io::stdin().lock().read_to_end(&mut input) {
        eprintln!("linediff: cannot read stdin: {e}");
        return ExitCode::from(2);
    }
    let mut out = BufWriter::with_capacity(1 << 16, io::stdout().lock());
    let result = linediff::format::run(&input, &mut out);
    let result = result.and_then(|()| out.flush().map_err(Into::into));
    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("linediff: {e}");
            ExitCode::FAILURE
        }
    }
}
