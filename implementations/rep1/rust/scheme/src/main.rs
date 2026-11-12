//! Command-line interface: reads a Scheme program on stdin and writes its
//! output to stdout. Always exits 0 unless the process itself fails.

use std::io::{self, BufWriter, Read};
use std::process::ExitCode;

/// Stack for the interpreter thread; non-tail recursion nests on the host stack.
const STACK_SIZE: usize = 1 << 30;

fn main() -> ExitCode {
    let mut input = Vec::new();
    if let Err(e) = io::stdin().lock().read_to_end(&mut input) {
        eprintln!("scheme: cannot read stdin: {e}");
        return ExitCode::from(2);
    }
    let src = String::from_utf8_lossy(&input).into_owned();

    let worker = std::thread::Builder::new().stack_size(STACK_SIZE).spawn(move || {
        let stdout = io::stdout().lock();
        scheme::run_program(&src, BufWriter::with_capacity(1 << 16, stdout))
    });
    match worker.map(|h| h.join()) {
        Ok(Ok(Ok(()))) => ExitCode::SUCCESS,
        Ok(Ok(Err(e))) if e.kind() == io::ErrorKind::BrokenPipe => ExitCode::SUCCESS,
        Ok(Ok(Err(e))) => {
            eprintln!("scheme: write error: {e}");
            ExitCode::from(1)
        }
        _ => {
            eprintln!("scheme: interpreter thread failed");
            ExitCode::from(1)
        }
    }
}
