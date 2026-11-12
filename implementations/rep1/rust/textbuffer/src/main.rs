//! Command-line front end: reads a script on stdin, writes the output of
//! every `print` command to stdout. See the README for the format.

use std::io::{self, BufWriter, Read, Write};
use std::process::ExitCode;

fn main() -> ExitCode {
    let mut input = Vec::new();
    if let Err(e) = io::stdin().lock().read_to_end(&mut input) {
        eprintln!("textbuffer: cannot read stdin: {e}");
        return ExitCode::from(2);
    }
    let stdout = io::stdout();
    let mut out = BufWriter::with_capacity(1 << 16, stdout.lock());
    let result = textbuffer::script::run(&input, &mut out);
    let flushed = out.flush();
    match (result, flushed) {
        (Ok(()), Ok(())) => ExitCode::SUCCESS,
        (Err(e), _) => {
            eprintln!("textbuffer: {e}");
            ExitCode::FAILURE
        }
        (Ok(()), Err(e)) => {
            eprintln!("textbuffer: {e}");
            ExitCode::FAILURE
        }
    }
}
