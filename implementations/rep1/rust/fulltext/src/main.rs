//! Command-line front end: `fulltext <input dir> <output dir>`.
//!
//! Reads `<input>/docs/*.txt` and `<input>/queries.txt`, and writes
//! `results.txt` and `stats.txt` into the output directory.

use fulltext::report::{run_queries, stats};
use fulltext::Index;
use std::env;
use std::fs;
use std::path::Path;
use std::process::ExitCode;

fn run(input: &Path, output: &Path) -> std::io::Result<()> {
    let index = Index::from_directory(input)?;
    let queries = fs::read(input.join("queries.txt"))?;
    let queries = String::from_utf8_lossy(&queries);
    fs::create_dir_all(output)?;
    fs::write(output.join("results.txt"), run_queries(&index, &queries))?;
    fs::write(output.join("stats.txt"), stats(&index))?;
    Ok(())
}

fn main() -> ExitCode {
    let args: Vec<String> = env::args().collect();
    if args.len() != 3 {
        eprintln!("usage: {} <input directory> <output directory>", args[0]);
        return ExitCode::from(2);
    }
    match run(Path::new(&args[1]), Path::new(&args[2])) {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("error: {e}");
            ExitCode::FAILURE
        }
    }
}
