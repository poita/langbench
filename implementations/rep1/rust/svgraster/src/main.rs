//! Command-line front end: `svgraster <input-dir> <output-dir>`.
//!
//! Reads `<input-dir>/render.txt`, renders every listed SVG and writes one
//! `.ppm` per SVG into `<output-dir>`.

use std::path::Path;
use std::process::ExitCode;

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.len() != 2 {
        eprintln!("usage: svgraster <input-dir> <output-dir>");
        return ExitCode::from(2);
    }
    match svgraster::jobs::render_directory(Path::new(&args[0]), Path::new(&args[1])) {
        Ok(failures) if failures.is_empty() => ExitCode::SUCCESS,
        Ok(failures) => {
            for (name, err) in failures {
                eprintln!("svgraster: {name}: {err}");
            }
            ExitCode::FAILURE
        }
        Err(e) => {
            eprintln!("svgraster: {e}");
            ExitCode::FAILURE
        }
    }
}
