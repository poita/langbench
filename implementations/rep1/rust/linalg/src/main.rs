//! Command-line driver: `linalg <input directory> <output directory>`.

use std::path::Path;
use std::process::ExitCode;

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().collect();
    if args.len() != 3 {
        eprintln!("usage: {} <input directory> <output directory>", args[0]);
        return ExitCode::from(2);
    }
    match linalg::script::run_dir(Path::new(&args[1]), Path::new(&args[2])) {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("linalg: {e}");
            ExitCode::FAILURE
        }
    }
}
