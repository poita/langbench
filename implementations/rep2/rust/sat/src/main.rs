//! `sat`: reads a DIMACS CNF formula on stdin and prints `UNSAT`, or `SAT`
//! followed by a satisfying assignment, on stdout.

use std::io::{self, Read, Write};
use std::process::ExitCode;

use cdcl_sat::{format_result, Cnf};

fn main() -> ExitCode {
    let mut input = String::new();
    if let Err(e) = io::stdin().read_to_string(&mut input) {
        eprintln!("sat: cannot read stdin: {e}");
        return ExitCode::from(2);
    }
    let cnf = match Cnf::parse(&input) {
        Ok(cnf) => cnf,
        Err(e) => {
            eprintln!("sat: {e}");
            return ExitCode::from(2);
        }
    };
    let out = format_result(&cnf.solve());
    let mut stdout = io::stdout().lock();
    if stdout.write_all(out.as_bytes()).and_then(|_| stdout.flush()).is_err() {
        return ExitCode::from(2);
    }
    ExitCode::SUCCESS
}
