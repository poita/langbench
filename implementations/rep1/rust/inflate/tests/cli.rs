//! End-to-end tests of the command-line tool.

use std::io::Write;
use std::process::{Command, Stdio};

fn run(input: &str) -> String {
    let mut child = Command::new(env!("CARGO_BIN_EXE_inflate"))
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    child.stdin.take().unwrap().write_all(input.as_bytes()).unwrap();
    let out = child.wait_with_output().unwrap();
    assert!(out.status.success());
    String::from_utf8(out.stdout).unwrap()
}

#[test]
fn prints_hex_output() {
    assert_eq!(run("4b4c4a862000\n"), "616263616263616263\n");
    assert_eq!(run("010100feff41\n"), "41\n");
}

#[test]
fn empty_output_is_an_empty_line() {
    assert_eq!(run("0300\n"), "\n");
}

#[test]
fn malformed_streams_print_error_and_exit_zero() {
    assert_eq!(run("\n"), "error\n");
    assert_eq!(run("030200\n"), "error\n");
    assert_eq!(run("030000\n"), "error\n");
}
