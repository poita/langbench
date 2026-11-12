//! End-to-end tests of the command-line binary.

use std::io::Write;
use std::process::{Command, Stdio};

fn run_cli(input: &str) -> (bool, String) {
    let mut child = Command::new(env!("CARGO_BIN_EXE_chip8"))
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .expect("spawn chip8");
    child.stdin.take().unwrap().write_all(input.as_bytes()).unwrap();
    let out = child.wait_with_output().unwrap();
    (out.status.success(), String::from_utf8(out.stdout).unwrap())
}

#[test]
fn prints_34_lines() {
    let (ok, out) = run_cli("60ff7001610180141208\n6");
    assert!(ok);
    assert_eq!(out.lines().count(), 34);
    assert!(out.ends_with("V=01 01 00 00 00 00 00 00 00 00 00 00 00 00 00 00\n"));
}

#[test]
fn malformed_input_fails() {
    let (ok, out) = run_cli("nothex\n5\n");
    assert!(!ok);
    assert!(out.is_empty());
}
