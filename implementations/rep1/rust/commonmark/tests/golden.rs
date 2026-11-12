//! Golden tests: every `tests/cases/*.in` is converted and compared with the
//! matching `.out` file (expected output of `cmark` 0.31.2). Like the
//! reference runner, trailing whitespace on each line and trailing newlines
//! are ignored.

use std::fs;
use std::path::Path;

fn normalise(s: &str) -> String {
    let lines: Vec<&str> = s.split('\n').map(|l| l.trim_end()).collect();
    lines.join("\n").trim_end_matches('\n').to_string()
}

#[test]
fn golden_cases() {
    let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/cases");
    let mut names: Vec<_> = fs::read_dir(&dir)
        .unwrap()
        .map(|e| e.unwrap().path())
        .filter(|p| p.extension().is_some_and(|e| e == "in"))
        .collect();
    names.sort();
    assert!(names.len() > 50);
    let mut failures = Vec::new();
    for input in &names {
        let src = fs::read_to_string(input).unwrap();
        let expected = fs::read_to_string(input.with_extension("out")).unwrap();
        let got = commonmark::to_html(&src);
        if normalise(&got) != normalise(&expected) {
            failures.push(input.file_name().unwrap().to_string_lossy().into_owned());
        }
    }
    assert!(failures.is_empty(), "failing cases: {failures:?}");
}
