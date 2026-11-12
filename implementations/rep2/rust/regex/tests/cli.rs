//! End-to-end tests of the command-line binary.

use std::io::Write;
use std::process::{Command, Stdio};

fn run(input: &str) -> (String, i32) {
    let mut child = Command::new(env!("CARGO_BIN_EXE_btregex"))
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    child.stdin.take().unwrap().write_all(input.as_bytes()).unwrap();
    let out = child.wait_with_output().unwrap();
    (
        String::from_utf8(out.stdout).unwrap(),
        out.status.code().unwrap(),
    )
}

#[test]
fn example_two() {
    let input = "2\n(a|(b))+\n2\nba\nab\n[^a-c]\\d{2,3}x?\n2\nzz123xx\nabc9\n";
    let (out, code) = run(input);
    assert_eq!(code, 0);
    assert_eq!(out, "match 0 2|1,2|0,1\nmatch 0 2|1,2|1,2\nmatch 1 6\nno\n");
}

#[test]
fn example_three() {
    let input = "3\n(a*)*b\n2\naab\nccc\nx$|^(y)?z\n3\nxz\nyz\nzzz\n(a){0}b|(c)?(d)\n3\nxb\nxcd\nd\n";
    let (out, code) = run(input);
    assert_eq!(code, 0);
    assert_eq!(
        out,
        "match 0 3|2,2\nno\nno\nmatch 0 2|0,1\nmatch 0 1|-\nmatch 1 2|-|-|-\nmatch 1 3|-|1,2|2,3\nmatch 0 1|-|-|0,1\n"
    );
}

#[test]
fn no_subjects_means_empty_output() {
    assert_eq!(run("1\nabc\n0\n"), (String::new(), 0));
}

#[test]
fn space_only_pattern_and_numeric_looking_subjects() {
    let (out, code) = run("2\n  \n2\n   \n \n1\n1\n1\n");
    assert_eq!(code, 0);
    assert_eq!(out, "match 0 2\nno\nmatch 0 1\n");
}

#[test]
fn malformed_input_fails() {
    let (_, code) = run("2\na\n1\nx\n");
    assert_ne!(code, 0);
}
