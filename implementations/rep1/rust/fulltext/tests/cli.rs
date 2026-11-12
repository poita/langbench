//! End-to-end tests: run the compiled binary on a temporary input directory.

use std::fs;
use std::path::PathBuf;
use std::process::Command;

fn scratch(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("fulltext-test-{}-{name}", std::process::id()));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).unwrap();
    dir
}

fn run(name: &str, docs: &[(&str, &str)], queries: &str) -> (String, String) {
    let root = scratch(name);
    let input = root.join("in");
    let output = root.join("out");
    fs::create_dir_all(&output).unwrap();
    fs::create_dir_all(input.join("docs")).unwrap();
    for (id, text) in docs {
        fs::write(input.join("docs").join(format!("{id}.txt")), text).unwrap();
    }
    fs::write(input.join("queries.txt"), queries).unwrap();
    let status = Command::new(env!("CARGO_BIN_EXE_fulltext")).arg(&input).arg(&output).status().unwrap();
    assert!(status.success());
    let results = fs::read_to_string(output.join("results.txt")).unwrap();
    let stats = fs::read_to_string(output.join("stats.txt")).unwrap();
    let _ = fs::remove_dir_all(&root);
    (results, stats)
}

#[test]
fn worked_example() {
    let (results, stats) = run(
        "worked",
        &[("note", "The quick brown fox jumps over the lazy dog.\n")],
        "fox\nquick brown\ncat\n\"lazy dog\"\n",
    );
    assert!(results.starts_with("QUERY 1 fox\nHITS 1\n1\tnote\t0.2877\tThe quick"));
    assert!(results.contains("QUERY 3 cat\nHITS 0\n"));
    assert_eq!(stats, "documents 1\ntokens 9\nterms 8\navgdl 9.0000\n");
}

#[test]
fn missing_docs_directory_and_non_txt_files() {
    let root = scratch("nodocs");
    let input = root.join("in");
    fs::create_dir_all(&input).unwrap();
    fs::write(input.join("queries.txt"), "cat").unwrap();
    let out = root.join("out");
    fs::create_dir_all(&out).unwrap();
    let status = Command::new(env!("CARGO_BIN_EXE_fulltext")).arg(&input).arg(&out).status().unwrap();
    assert!(status.success());
    assert_eq!(fs::read_to_string(out.join("results.txt")).unwrap(), "QUERY 1 cat\nHITS 0\n");
    assert_eq!(
        fs::read_to_string(out.join("stats.txt")).unwrap(),
        "documents 0\ntokens 0\nterms 0\navgdl 0.0000\n"
    );
    let _ = fs::remove_dir_all(&root);
}

#[test]
fn empty_document_has_empty_snippet() {
    let (results, _) = run("empty", &[("e", ""), ("f", "word")], "NOT word");
    assert_eq!(results, "QUERY 1 NOT word\nHITS 1\n1\te\t0.0000\t\n");
}

#[test]
fn snippet_window_and_k_directive() {
    let words: Vec<String> = (0..100).map(|i| format!("w{i}")).collect();
    let text = words.join("\n  ");
    let (results, _) = run("window", &[("d", &text)], "%k 1\nw90\n");
    let line = results.lines().nth(2).unwrap();
    let snippet = line.split('\t').nth(3).unwrap();
    assert_eq!(snippet.split(' ').count(), 30);
    assert!(snippet.contains("w90"));
    assert!(snippet.starts_with("w61 ") && snippet.ends_with(" w90"));
}
