//! Command-line interface: `sitegen <input directory> <output directory>`.

use std::path::PathBuf;
use std::process::ExitCode;

/// Rendering is recursive in the depth of the input (nested block quotes,
/// emphasis, macros), so run on a thread with a generous stack.
const STACK_SIZE: usize = 512 * 1024 * 1024;

fn run(args: Vec<String>) -> ExitCode {
    if args.len() != 2 {
        eprintln!("usage: sitegen <input directory> <output directory>");
        return ExitCode::from(2);
    }
    let input = PathBuf::from(&args[0]);
    let output = PathBuf::from(&args[1]);
    match sitegen::generate(&input, &output) {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("sitegen: {}", e);
            ExitCode::FAILURE
        }
    }
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let handle = std::thread::Builder::new()
        .stack_size(STACK_SIZE)
        .spawn(move || run(args));
    match handle.map(|h| h.join()) {
        Ok(Ok(code)) => code,
        Ok(Err(_)) => ExitCode::FAILURE,
        Err(e) => {
            eprintln!("sitegen: cannot start worker thread: {}", e);
            ExitCode::FAILURE
        }
    }
}
