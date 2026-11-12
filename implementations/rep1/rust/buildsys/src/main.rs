//! Command-line front end: `buildsys <input directory> <output directory>`.

use std::path::PathBuf;
use std::process::ExitCode;

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.len() != 2 {
        eprintln!("usage: buildsys <input directory> <output directory>");
        return ExitCode::from(2);
    }
    let (input, output) = (PathBuf::from(&args[0]), PathBuf::from(&args[1]));
    // Evaluation recurses with the nesting of the build files, so run on a
    // thread with a generous stack.
    let worker = std::thread::Builder::new()
        .stack_size(512 * 1024 * 1024)
        .spawn(move || buildsys::run_directory(&input, &output));
    match worker.map(|h| h.join()) {
        Ok(Ok(Ok(()))) => ExitCode::SUCCESS,
        Ok(Ok(Err(e))) => {
            eprintln!("buildsys: {e}");
            ExitCode::FAILURE
        }
        _ => {
            eprintln!("buildsys: internal error");
            ExitCode::FAILURE
        }
    }
}
