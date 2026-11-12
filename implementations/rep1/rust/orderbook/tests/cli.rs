//! End-to-end tests of the command-line binary.

use std::io::Write;
use std::process::{Command, Stdio};

fn run_cli(input: &[u8]) -> (String, bool) {
    let mut child = Command::new(env!("CARGO_BIN_EXE_orderbook"))
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    child.stdin.take().unwrap().write_all(input).unwrap();
    let out = child.wait_with_output().unwrap();
    (String::from_utf8(out.stdout).unwrap(), out.status.success())
}

#[test]
fn matches_example() {
    let (out, ok) = run_cli(include_bytes!("fixtures/example3.in"));
    assert!(ok);
    assert_eq!(out, include_str!("fixtures/example3.out"));
}

#[test]
fn empty_input_gives_empty_output() {
    let (out, ok) = run_cli(b"0\n");
    assert!(ok);
    assert_eq!(out, "");
}

#[test]
fn no_trailing_newline() {
    let (out, ok) = run_cli(b"2\nLIMIT a BUY 1 1\nBOOK");
    assert!(ok);
    assert_eq!(out, "REST a\nBID 1 1 1\n--\n");
}

#[test]
fn malformed_input_fails() {
    let (_, ok) = run_cli(b"1\nGARBAGE\n");
    assert!(!ok);
}
