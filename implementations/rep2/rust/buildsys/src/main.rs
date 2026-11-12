//! Command-line driver: `kiln <input directory> <output directory>`.
//!
//! Reads `session.txt` and the initial workspace from the input directory,
//! runs the session, and writes `log.txt` and the final `workspace/` tree into
//! the output directory.

use std::fs;
use std::path::Path;
use std::process::ExitCode;

use kiln::{Session, Workspace};

fn run(input: &Path, output: &Path) -> Result<(), String> {
    let script = fs::read(input.join("session.txt"))
        .map_err(|e| format!("cannot read session.txt: {e}"))?;
    let session = Session::parse(&script).map_err(|e| e.to_string())?;
    let mut ws = Workspace::load_dir(input).map_err(|e| format!("cannot load workspace: {e}"))?;
    let log = session.run(&mut ws);
    fs::create_dir_all(output).map_err(|e| format!("cannot create output directory: {e}"))?;
    fs::write(output.join("log.txt"), log).map_err(|e| format!("cannot write log.txt: {e}"))?;
    ws.write_dir(&output.join("workspace"))
        .map_err(|e| format!("cannot write workspace: {e}"))?;
    Ok(())
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().collect();
    if args.len() != 3 {
        eprintln!("usage: {} <input directory> <output directory>", args[0]);
        return ExitCode::from(2);
    }
    let (input, output) = (args[1].clone(), args[2].clone());
    // Deeply nested expressions recurse; give the interpreter a roomy stack.
    let worker = std::thread::Builder::new()
        .stack_size(512 * 1024 * 1024)
        .spawn(move || run(Path::new(&input), Path::new(&output)));
    match worker.map(|h| h.join()) {
        Ok(Ok(Ok(()))) => ExitCode::SUCCESS,
        Ok(Ok(Err(msg))) => {
            eprintln!("kiln: {msg}");
            ExitCode::FAILURE
        }
        _ => {
            eprintln!("kiln: internal error");
            ExitCode::FAILURE
        }
    }
}
