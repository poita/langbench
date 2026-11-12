//! Command-line front end: reads one scramble per line on stdin and prints
//! one solution per line on stdout.

use rubiks::{format_moves, CubieCube, Move, Solver};
use std::io::{self, Read, Write};
use std::process::ExitCode;

fn run() -> Result<(), String> {
    let mut input = Vec::new();
    io::stdin().lock().read_to_end(&mut input).map_err(|e| format!("reading stdin: {e}"))?;
    if input.is_empty() {
        return Ok(());
    }

    let mut lines: Vec<&[u8]> = input.split(|&b| b == b'\n').collect();
    if input.ends_with(b"\n") {
        lines.pop(); // the empty piece after the final newline is not a scramble
    }

    let solver = Solver::new();
    let mut out = io::BufWriter::new(io::stdout().lock());
    for (n, line) in lines.iter().enumerate() {
        let mut cube = CubieCube::SOLVED;
        for tok in line.split(|&b| b == b' ').filter(|t| !t.is_empty()) {
            let m = Move::from_bytes(tok).map_err(|e| format!("line {}: {e}", n + 1))?;
            cube = cube.apply(m);
        }
        let solution = solver.solve(&cube).map_err(|e| format!("line {}: {e}", n + 1))?;
        writeln!(out, "{}", format_moves(&solution)).map_err(|e| format!("writing stdout: {e}"))?;
    }
    out.flush().map_err(|e| format!("writing stdout: {e}"))
}

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(msg) => {
            eprintln!("rubiks: {msg}");
            ExitCode::FAILURE
        }
    }
}
