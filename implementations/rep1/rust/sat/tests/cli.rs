//! End-to-end tests of the `sat` binary.

use std::io::Write;
use std::process::{Command, Stdio};

fn run(input: &str) -> (String, Option<i32>) {
    let mut child = Command::new(env!("CARGO_BIN_EXE_sat"))
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    child.stdin.take().unwrap().write_all(input.as_bytes()).unwrap();
    let out = child.wait_with_output().unwrap();
    (String::from_utf8(out.stdout).unwrap(), out.status.code())
}

#[test]
fn sat_output_format() {
    let (out, code) = run("p cnf 3 2\n1 0\n-3 0");
    assert_eq!(out, "SAT\n1 -2 -3 0\n"); // variable 2 is free: saved phase is false
    assert_eq!(code, Some(0));
}

#[test]
fn unsat_output_format() {
    let (out, code) = run("p cnf 1 2\n1 0\n-1 0\n");
    assert_eq!(out, "UNSAT\n");
    assert_eq!(code, Some(0));
}

#[test]
fn zero_variables() {
    assert_eq!(run("p cnf 0 0\n").0, "SAT\n0\n");
}

#[test]
fn malformed_input_fails_with_nonzero_status() {
    let (out, code) = run("1 0\n");
    assert!(out.is_empty());
    assert_eq!(code, Some(2));
}
