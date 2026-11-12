//! Command-line front end: `gitrepo <input dir> <output dir>`.
//!
//! The input directory holds `repo/` (a git object database) and
//! `commands.txt`. For command number *k* the file `NNN.out` is written to
//! the output directory; a command that fails writes `error`.

use std::fs;
use std::path::Path;
use std::process::ExitCode;

use gitrepo::{commands, Repository};

fn run(input: &Path, output: &Path) -> std::io::Result<()> {
    let text = fs::read(input.join("commands.txt"))?;
    let repo = Repository::open(&input.join("repo"));
    fs::create_dir_all(output)?;
    let mut lines: Vec<&[u8]> = text.split(|&b| b == b'\n').collect();
    if lines.last().is_some_and(|l| l.is_empty()) {
        lines.pop();
    }
    for (k, line) in lines.iter().enumerate() {
        let answer = match &repo {
            Ok(repo) => commands::execute(repo, line),
            Err(e) => Err(e.clone()),
        };
        let bytes = answer.unwrap_or_else(|_| b"error\n".to_vec());
        fs::write(output.join(format!("{:03}.out", k + 1)), bytes)?;
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
            eprintln!("gitrepo: {e}");
            ExitCode::FAILURE
        }
    }
}
