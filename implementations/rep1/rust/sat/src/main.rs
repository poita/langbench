//! Command-line front end: reads DIMACS CNF on stdin, prints `SAT` and a
//! model line, or `UNSAT`, on stdout.

use std::io::{self, Read, Write};
use std::process::ExitCode;

fn main() -> ExitCode {
    let mut input = String::new();
    if let Err(e) = io::stdin().read_to_string(&mut input) {
        eprintln!("sat: cannot read stdin: {e}");
        return ExitCode::from(2);
    }
    match cdcl_sat::solve_dimacs(&input) {
        Ok(out) => {
            let mut stdout = io::stdout().lock();
            if stdout.write_all(out.as_bytes()).and_then(|_| stdout.flush()).is_err() {
                return ExitCode::from(2);
            }
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!("sat: {e}");
            ExitCode::from(2)
        }
    }
}
