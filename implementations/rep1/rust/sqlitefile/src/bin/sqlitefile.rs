//! Command-line front end: `sqlitefile <input dir> <output dir>`.
//!
//! The input directory holds one `*.sqlite` database and `queries.txt` with
//! one query per line; query *n* writes its result to `NNN.txt` in the output
//! directory. A failing query writes the single line `error`. The exit status
//! is 0 unless the arguments or directories themselves are unusable.

use sqlitefile::Engine;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::ExitCode;

fn find_database(dir: &Path) -> std::io::Result<Option<PathBuf>> {
    let mut found: Vec<PathBuf> = Vec::new();
    for entry in fs::read_dir(dir)? {
        let path = entry?.path();
        if path.is_file() && path.extension().is_some_and(|e| e == "sqlite") {
            found.push(path);
        }
    }
    found.sort();
    Ok(found.into_iter().next())
}

fn run(input: &Path, output: &Path) -> Result<(), Box<dyn std::error::Error>> {
    let queries = fs::read_to_string(input.join("queries.txt"))?;
    let engine = find_database(input)?
        .ok_or("no .sqlite file in input directory")
        .map_err(|e| e.to_string())
        .and_then(|p| Engine::open(p).map_err(|e| e.to_string()));
    if let Err(e) = &engine {
        eprintln!("sqlitefile: {e}");
    }
    let mut lines: Vec<&str> = queries.split('\n').collect();
    if lines.last() == Some(&"") {
        lines.pop();
    }
    for (i, line) in lines.iter().enumerate() {
        let result = match &engine {
            Ok(e) => e.execute_or_error(line),
            Err(_) => "error\n".to_string(),
        };
        fs::write(output.join(format!("{:03}.txt", i + 1)), result)?;
    }
    Ok(())
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().collect();
    if args.len() != 3 {
        eprintln!("usage: {} <input dir> <output dir>", args[0]);
        return ExitCode::from(2);
    }
    match run(Path::new(&args[1]), Path::new(&args[2])) {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("sqlitefile: {e}");
            ExitCode::FAILURE
        }
    }
}
