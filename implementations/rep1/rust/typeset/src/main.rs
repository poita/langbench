//! Command-line front end: `typeset <input directory> <output directory>`.
//!
//! Font metrics and hyphenation patterns are read from `data/` relative to
//! the current working directory (override with `TYPESET_DATA`). Invalid
//! documents are reported in `error.txt`; the exit code is still 0.

use std::path::PathBuf;
use std::process::ExitCode;

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.len() != 2 {
        eprintln!("usage: typeset <input directory> <output directory>");
        return ExitCode::from(2);
    }
    let data = std::env::var_os("TYPESET_DATA").map(PathBuf::from).unwrap_or_else(|| PathBuf::from("data"));
    match typeset::run_dir(args[0].as_ref(), args[1].as_ref(), &data) {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("typeset: {e}");
            ExitCode::FAILURE
        }
    }
}
