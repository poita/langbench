//! Command-line front end: reads a registry and root manifest on stdin and
//! prints the resolution (or `unsatisfiable`) on stdout.

use std::io::{self, Read, Write};
use std::process::ExitCode;

fn main() -> ExitCode {
    let mut raw = Vec::new();
    if let Err(e) = io::stdin().lock().read_to_end(&mut raw) {
        eprintln!("depresolve: cannot read stdin: {e}");
        return ExitCode::from(2);
    }
    let text = match String::from_utf8(raw) {
        Ok(t) => t,
        Err(_) => {
            eprintln!("depresolve: input is not valid UTF-8");
            return ExitCode::from(2);
        }
    };
    let input = match depresolve::parse_input(&text) {
        Ok(i) => i,
        Err(e) => {
            eprintln!("depresolve: {e}");
            return ExitCode::from(2);
        }
    };
    let out = match depresolve::resolve(&input.registry, &input.root) {
        Some(solution) => solution.to_string(),
        None => "unsatisfiable\n".to_string(),
    };
    let mut stdout = io::stdout().lock();
    if stdout.write_all(out.as_bytes()).and_then(|_| stdout.flush()).is_err() {
        return ExitCode::from(1);
    }
    ExitCode::SUCCESS
}
