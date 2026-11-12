//! Runs the worked examples of the language specification (sections 17.1 to
//! 17.17): each `tests/examples/NAME.in` is a complete module stream and
//! `NAME.out` is the exact expected stdout.

use std::fs;
use std::path::Path;

#[test]
fn worked_examples() {
    let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/examples");
    let mut names: Vec<_> = fs::read_dir(&dir)
        .unwrap()
        .filter_map(|e| e.ok())
        .map(|e| e.path())
        .filter(|p| p.extension().map_or(false, |x| x == "in"))
        .collect();
    names.sort();
    assert!(names.len() >= 26, "expected the spec examples to be present");
    for input in names {
        let expected = fs::read_to_string(input.with_extension("out")).unwrap();
        let source = fs::read_to_string(&input).unwrap();
        let actual = langvm::run_source(&source);
        assert_eq!(actual, expected, "example {}", input.display());
    }
}
