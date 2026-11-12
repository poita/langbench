//! Command-line front end: reads a batch of patterns and subjects from stdin
//! and prints the first match (with capture positions) for every subject.
//! See `btregex::batch` for the format.

use std::io::{self, Read, Write};
use std::process::ExitCode;

fn main() -> ExitCode {
    let mut input = Vec::new();
    if let Err(e) = io::stdin().lock().read_to_end(&mut input) {
        eprintln!("btregex: cannot read stdin: {e}");
        return ExitCode::from(2);
    }
    let stdout = io::stdout();
    let mut out = io::BufWriter::with_capacity(1 << 16, stdout.lock());
    let result = btregex::batch::process(&input, &mut out);
    let flushed = out.flush();
    match result {
        Ok(()) => match flushed {
            Ok(()) => ExitCode::SUCCESS,
            Err(e) => {
                eprintln!("btregex: {e}");
                ExitCode::from(2)
            }
        },
        Err(e) => {
            eprintln!("btregex: {e}");
            ExitCode::FAILURE
        }
    }
}
