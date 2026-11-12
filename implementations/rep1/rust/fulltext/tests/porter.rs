//! Checks the stemmer against Porter's published test vocabulary, when it is
//! available next to this project (`../problems/fulltext/corpus/porter`).

use fulltext::stemmer::stem;
use std::fs;
use std::path::Path;

#[test]
fn porter_vocabulary() {
    let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("../problems/fulltext/corpus/porter");
    let (Ok(voc), Ok(out)) = (fs::read_to_string(dir.join("voc.txt")), fs::read_to_string(dir.join("output.txt")))
    else {
        eprintln!("porter vocabulary not found; skipping");
        return;
    };
    let words: Vec<&str> = voc.lines().collect();
    let stems: Vec<&str> = out.lines().collect();
    assert_eq!(words.len(), stems.len());
    let bad: Vec<_> = words
        .iter()
        .zip(&stems)
        .filter(|(w, s)| stem(w) != **s)
        .take(10)
        .collect();
    assert!(bad.is_empty(), "mismatches: {bad:?}");
}
