//! Command-line driver: reads a command script on stdin and prints one line
//! of output per command on stdout. See the README for the format.

use std::io::{self, BufWriter, Read, Write};
use std::process::ExitCode;

fn main() -> ExitCode {
    let mut input = String::new();
    if let Err(e) = io::stdin().lock().read_to_string(&mut input) {
        eprintln!("ordered-map: cannot read stdin: {e}");
        return ExitCode::FAILURE;
    }
    let stdout = io::stdout();
    let mut out = BufWriter::with_capacity(1 << 16, stdout.lock());
    let result = ordered_map::run(&input, &mut out).and_then(|()| out.flush());
    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            // Flush whatever was produced before the error, best effort.
            let _ = out.flush();
            eprintln!("ordered-map: {e}");
            ExitCode::FAILURE
        }
    }
}
