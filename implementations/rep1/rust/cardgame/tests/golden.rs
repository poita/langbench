//! Golden tests: every `tests/cases/*.in` match file is run and its output is
//! compared with the neighbouring `.out` file (trailing whitespace and
//! trailing newlines ignored). The cases include the worked examples of the
//! specification. `data/` in a `CARDS` line refers to `tests/fixtures/data/`.

use std::fs;
use std::path::PathBuf;

fn fixtures() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures")
}

fn normalise(s: &str) -> Vec<String> {
    let mut lines: Vec<String> = s.lines().map(|l| l.trim_end().to_string()).collect();
    while lines.last().is_some_and(|l| l.is_empty()) {
        lines.pop();
    }
    lines
}

#[test]
fn golden_cases() {
    let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/cases");
    let data = fixtures().join("data");
    let mut names: Vec<PathBuf> = fs::read_dir(&dir)
        .unwrap()
        .map(|e| e.unwrap().path())
        .filter(|p| p.extension().is_some_and(|e| e == "in"))
        .collect();
    names.sort();
    assert!(!names.is_empty());
    let mut failures = Vec::new();
    for path in &names {
        let input = fs::read_to_string(path).unwrap();
        let input = input.replace("CARDS data/", &format!("CARDS {}/", data.display()));
        let expected = fs::read_to_string(path.with_extension("out")).unwrap();
        let got = cardgame::run_match(&input);
        if normalise(&got) != normalise(&expected) {
            failures.push(path.file_name().unwrap().to_string_lossy().to_string());
        }
    }
    assert!(failures.is_empty(), "golden cases differ: {failures:?}");
}
