//! End-to-end tests of the command-line binary.

use std::io::Write;
use std::process::{Command, Stdio};

fn run(input: &str) -> (String, bool) {
    let mut child = Command::new(env!("CARGO_BIN_EXE_softfloat"))
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
fn example_one() {
    let input = "add 3f800000 3f800000\nsub 3f800000 3f800000\nmul 40400000 c0400000\n\
                 div 3f800000 40400000\nsqrt 40000000\n";
    let (out, ok) = run(input);
    assert!(ok);
    assert_eq!(out, "40000000\n00000000\nc1100000\n3eaaaaab\n3fb504f3\n");
}

#[test]
fn no_trailing_newline() {
    let (out, ok) = run("sqrt 80000000");
    assert!(ok);
    assert_eq!(out, "80000000\n");
}

#[test]
fn malformed_input_fails() {
    let (_, ok) = run("add 1234\n");
    assert!(!ok);
}
