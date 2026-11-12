//! Tests of the command-line tool's I/O contract.

use std::io::Write;
use std::process::{Command, Stdio};

fn run_cli(input: &str) -> (String, i32) {
    let mut child = Command::new(env!("CARGO_BIN_EXE_scheme"))
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .expect("spawn scheme");
    child.stdin.take().unwrap().write_all(input.as_bytes()).unwrap();
    let out = child.wait_with_output().unwrap();
    (String::from_utf8(out.stdout).unwrap(), out.status.code().unwrap())
}

#[test]
fn prints_values_and_exits_zero() {
    assert_eq!(run_cli("(+ 1 2) (display \"hi\")"), ("3\nhi".to_string(), 0));
}

#[test]
fn runtime_error_still_exits_zero() {
    assert_eq!(run_cli("(display 1) (car 5) (display 2)"), ("1error: type-error\n".to_string(), 0));
}

#[test]
fn utf8_passes_through() {
    assert_eq!(run_cli("(display \"héllo ✓\")").0, "héllo ✓");
}

#[test]
fn handles_deep_recursion() {
    let src = "(define (sum n) (if (= n 0) 0 (+ n (sum (- n 1))))) (sum 100000)";
    assert_eq!(run_cli(src), ("5000050000\n".to_string(), 0));
}
