//! `kvstore <input dir> <output dir>`: runs `commands.txt` from the input
//! directory against the optional `main.tdb` / `main.twal` found there and
//! writes `results.txt`, `main.tdb` and `main.twal` to the output directory.

use std::fs;
use std::io;
use std::path::Path;
use std::process::ExitCode;

use tessera::Database;

fn read_optional(path: &Path) -> io::Result<Option<Vec<u8>>> {
    match fs::read(path) {
        Ok(b) => Ok(Some(b)),
        Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(None),
        Err(e) => Err(e),
    }
}

fn run(input: &Path, output: &Path) -> Result<(), String> {
    let io_err = |what: &str, e: io::Error| format!("{what}: {e}");
    let commands = read_optional(&input.join("commands.txt"))
        .map_err(|e| io_err("reading commands.txt", e))?
        .unwrap_or_default();
    let main = read_optional(&input.join("main.tdb")).map_err(|e| io_err("reading main.tdb", e))?;
    let log = read_optional(&input.join("main.twal")).map_err(|e| io_err("reading main.twal", e))?;

    let mut db = Database::open(main.as_deref(), log.as_deref()).map_err(|e| format!("opening database: {e}"))?;
    let results = db.run_script(&String::from_utf8_lossy(&commands));

    fs::create_dir_all(output).map_err(|e| io_err("creating output directory", e))?;
    fs::write(output.join("results.txt"), results).map_err(|e| io_err("writing results.txt", e))?;
    fs::write(output.join("main.tdb"), db.main_bytes()).map_err(|e| io_err("writing main.tdb", e))?;
    fs::write(output.join("main.twal"), db.wal_bytes()).map_err(|e| io_err("writing main.twal", e))?;
    Ok(())
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().collect();
    if args.len() != 3 {
        eprintln!("usage: {} <input dir> <output dir>", args.first().map_or("kvstore", String::as_str));
        return ExitCode::from(2);
    }
    let (input, output) = (args[1].clone(), args[2].clone());
    // Deeply nested predicates recurse; give the worker a generous stack.
    let worker = std::thread::Builder::new()
        .stack_size(512 * 1024 * 1024)
        .spawn(move || run(Path::new(&input), Path::new(&output)));
    match worker.map(|h| h.join()) {
        Ok(Ok(Ok(()))) => ExitCode::SUCCESS,
        Ok(Ok(Err(msg))) => {
            eprintln!("kvstore: {msg}");
            ExitCode::FAILURE
        }
        _ => {
            eprintln!("kvstore: internal error");
            ExitCode::FAILURE
        }
    }
}
