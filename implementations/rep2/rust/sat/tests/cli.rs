//! End-to-end tests of the `sat` binary.

use std::io::Write;
use std::process::{Command, Stdio};

fn run(input: &str) -> (String, i32) {
    let mut child = Command::new(env!("CARGO_BIN_EXE_sat"))
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .expect("spawn sat");
    child.stdin.take().unwrap().write_all(input.as_bytes()).unwrap();
    let out = child.wait_with_output().unwrap();
    (String::from_utf8(out.stdout).unwrap(), out.status.code().unwrap())
}

#[test]
fn satisfiable() {
    let (out, code) = run("c example\np cnf 3 2\n1 -2 0\n2 3 0\n");
    assert_eq!(code, 0);
    assert!(out.starts_with("SAT\n"));
    assert!(out.ends_with(" 0\n"));
}

#[test]
fn unsatisfiable_with_clauses_spanning_lines() {
    let (out, code) = run("p cnf 2 4\n1 2\n0 -1 2 0\n-1 -2 0 1 -2 0");
    assert_eq!((out.as_str(), code), ("UNSAT\n", 0));
}

#[test]
fn no_variables() {
    let (out, code) = run("p cnf 0 0");
    assert_eq!((out.as_str(), code), ("SAT\n0\n", 0));
}

#[test]
fn empty_clause() {
    let (out, code) = run("p cnf 2 2\n1 2 0\n0\n");
    assert_eq!((out.as_str(), code), ("UNSAT\n", 0));
}

#[test]
fn tautology_is_satisfied() {
    let (out, code) = run("p cnf 1 1\n1 -1 0\n");
    assert_eq!(code, 0);
    assert!(out.starts_with("SAT\n"));
}
