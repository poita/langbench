//! Runs the public test cases of the problem (`problems/kvstore/tests`, next
//! to this project) through the library, if they are present: each case's
//! `results.txt`, `main.tdb` and `main.twal` must match byte for byte (the
//! text file modulo trailing whitespace).

use std::fs;
use std::path::{Path, PathBuf};

use tessera::Database;

fn suite_dir() -> Option<PathBuf> {
    let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("../problems/kvstore/tests");
    dir.is_dir().then_some(dir)
}

fn read(path: &Path) -> Option<Vec<u8>> {
    fs::read(path).ok()
}

fn normalise(s: &str) -> String {
    s.lines().map(str::trim_end).collect::<Vec<_>>().join("\n").trim_end_matches('\n').to_string()
}

#[test]
fn public_cases() {
    let Some(dir) = suite_dir() else {
        eprintln!("problem tests not found; skipping");
        return;
    };
    let mut cases: Vec<_> = fs::read_dir(&dir).unwrap().map(|e| e.unwrap().path()).collect();
    cases.sort();
    let mut failures = Vec::new();
    for case in &cases {
        let input = case.join("input");
        let expected = case.join("expected");
        let Some(commands) = read(&input.join("commands.txt")) else { continue };
        let main = read(&input.join("main.tdb"));
        let log = read(&input.join("main.twal"));
        let mut db = Database::open(main.as_deref(), log.as_deref()).unwrap();
        let results = db.run_script(&String::from_utf8_lossy(&commands));
        let name = case.file_name().unwrap().to_string_lossy().to_string();
        let want = String::from_utf8(read(&expected.join("results.txt")).unwrap()).unwrap();
        if normalise(&results) != normalise(&want) {
            failures.push(format!("{name}: results.txt"));
        }
        if Some(db.main_bytes()) != read(&expected.join("main.tdb")).as_deref() {
            failures.push(format!("{name}: main.tdb"));
        }
        if Some(db.wal_bytes()) != read(&expected.join("main.twal")).as_deref() {
            failures.push(format!("{name}: main.twal"));
        }
    }
    assert!(failures.is_empty(), "failing cases: {failures:#?}");
}
