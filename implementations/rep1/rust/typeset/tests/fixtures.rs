//! Golden-file tests: every directory under `tests/fixtures/` holds an
//! `input/` directory and the `expected/` output tree it must produce.

use std::fs;
use std::path::{Path, PathBuf};

fn data_dir() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("data")
}

fn normalise(s: &str) -> String {
    s.lines().map(str::trim_end).collect::<Vec<_>>().join("\n").trim_end_matches('\n').to_string()
}

fn run_fixture(case: &Path) -> Result<(), String> {
    let out = std::env::temp_dir().join(format!("typeset-test-{}-{}", std::process::id(), case.file_name().unwrap().to_string_lossy()));
    let _ = fs::remove_dir_all(&out);
    typeset::run_dir(&case.join("input"), &out, &data_dir()).map_err(|e| e.to_string())?;
    let expected = case.join("expected");
    let mut names: Vec<String> = fs::read_dir(&expected)
        .unwrap()
        .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
        .collect();
    names.sort();
    let mut actual: Vec<String> =
        fs::read_dir(&out).unwrap().map(|e| e.unwrap().file_name().to_string_lossy().into_owned()).collect();
    actual.sort();
    if names != actual {
        return Err(format!("files differ: expected {names:?}, got {actual:?}"));
    }
    for n in names {
        let e = fs::read_to_string(expected.join(&n)).unwrap();
        let a = fs::read_to_string(out.join(&n)).unwrap();
        if normalise(&e) != normalise(&a) {
            return Err(format!("{n} differs"));
        }
    }
    let _ = fs::remove_dir_all(&out);
    Ok(())
}

#[test]
fn all_fixtures_match() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests").join("fixtures");
    let mut cases: Vec<PathBuf> = fs::read_dir(&root).unwrap().map(|e| e.unwrap().path()).collect();
    cases.sort();
    assert!(!cases.is_empty());
    let failures: Vec<String> = cases
        .iter()
        .filter_map(|c| run_fixture(c).err().map(|e| format!("{}: {e}", c.file_name().unwrap().to_string_lossy())))
        .collect();
    assert!(failures.is_empty(), "{} fixture(s) failed:\n{}", failures.len(), failures.join("\n"));
}
