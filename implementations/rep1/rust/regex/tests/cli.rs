//! End-to-end tests of the command-line tool.

use std::io::Write;
use std::process::{Command, Stdio};

fn run(input: &str) -> (String, bool) {
    let mut child = Command::new(env!("CARGO_BIN_EXE_btregex"))
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    child.stdin.take().unwrap().write_all(input.as_bytes()).unwrap();
    let out = child.wait_with_output().unwrap();
    (String::from_utf8(out.stdout).unwrap(), out.status.success())
}

#[test]
fn worked_example_1() {
    let input = "3\n(a|ab)(c|bcd)(d*)\n1\nabcd\na*\n2\nbbb\n\n^(a+)+$\n2\naaaa\naaab\n";
    let (out, ok) = run(input);
    assert!(ok);
    assert_eq!(out, "match 0 4|0,1|1,4|4,4\nmatch 0 0\nmatch 0 0\nmatch 0 4|0,4\nno\n");
}

#[test]
fn worked_example_2() {
    let input = "2\n(a|(b))+\n2\nba\nab\n[^a-c]\\d{2,3}x?\n2\nzz123xx\nabc9\n";
    let (out, ok) = run(input);
    assert!(ok);
    assert_eq!(out, "match 0 2|1,2|0,1\nmatch 0 2|1,2|1,2\nmatch 1 6\nno\n");
}

#[test]
fn worked_example_3() {
    let input = "3\n(a*)*b\n2\naab\nccc\nx$|^(y)?z\n3\nxz\nyz\nzzz\n(a){0}b|(c)?(d)\n3\nxb\nxcd\nd\n";
    let (out, ok) = run(input);
    assert!(ok);
    assert_eq!(
        out,
        "match 0 3|2,2\nno\nno\nmatch 0 2|0,1\nmatch 0 1|-\nmatch 1 2|-|-|-\nmatch 1 3|-|1,2|2,3\nmatch 0 1|-|-|0,1\n"
    );
}

#[test]
fn zero_subjects_produces_no_output() {
    let (out, ok) = run("2\na\n0\nb\n0\n");
    assert!(ok);
    assert_eq!(out, "");
}

#[test]
fn spaces_and_number_like_lines_are_verbatim() {
    // Pattern "  " with subjects "", "a  b", " 1 "; then pattern "12" (which
    // looks like a count) with the subject "x12"; then an empty pattern.
    let (out, ok) = run("3\n  \n3\n\na  b\n 1 \n12\n1\nx12\n\n1\nzz\n");
    assert!(ok);
    assert_eq!(out, "no\nmatch 1 3\nno\nmatch 1 3\nmatch 0 0\n");
}

#[test]
fn invalid_input_fails() {
    let (_, ok) = run("1\na\n3\nonly\n");
    assert!(!ok);
}
