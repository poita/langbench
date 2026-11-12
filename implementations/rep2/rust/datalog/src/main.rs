//! Command-line front end: reads a Datalog program on stdin and prints the
//! answers to its queries on stdout, or `error` if the program is unsafe or
//! not stratifiable.

use std::io::{Read, Write};
use std::process::ExitCode;

fn main() -> ExitCode {
    let mut source = String::new();
    if let Err(e) = std::io::stdin().read_to_string(&mut source) {
        eprintln!("datalog: cannot read stdin: {e}");
        return ExitCode::from(2);
    }
    match datalog::run(&source) {
        Ok(out) => {
            let mut stdout = std::io::stdout().lock();
            if stdout.write_all(out.as_bytes()).and_then(|_| stdout.flush()).is_err() {
                return ExitCode::from(2);
            }
            ExitCode::SUCCESS
        }
        Err(e) if e.is_semantic() => {
            eprintln!("datalog: {e}");
            println!("error");
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!("datalog: {e}");
            ExitCode::from(2)
        }
    }
}
