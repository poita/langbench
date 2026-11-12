//! End-to-end tests of the command-line tool.

use std::io::Write;
use std::process::{Command, Stdio};

fn run_cli(input: &str) -> (String, i32) {
    let mut child = Command::new(env!("CARGO_BIN_EXE_langvm"))
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .expect("spawn langvm");
    child.stdin.take().unwrap().write_all(input.as_bytes()).unwrap();
    let out = child.wait_with_output().unwrap();
    (String::from_utf8(out.stdout).unwrap(), out.status.code().unwrap())
}

#[test]
fn runs_a_program_and_exits_zero() {
    let (out, code) = run_cli("@module main\nfn main() { print(\"hello\"); }\n");
    assert_eq!(out, "hello\n");
    assert_eq!(code, 0);
}

#[test]
fn compile_errors_and_panics_still_exit_zero() {
    let (out, code) = run_cli("@module main\nfn main() { let x: Int = \"s\"; }\n");
    assert_eq!(out, "error: type-mismatch at 1:26\n");
    assert_eq!(code, 0);
    let (out, code) = run_cli("@module main\nfn main() { print(\"a\"); panic(\"b\"); }\n");
    assert_eq!(out, "a\npanic: b\n");
    assert_eq!(code, 0);
}

#[test]
fn accepts_crlf_line_endings() {
    let (out, _) = run_cli("@module main\r\nfn main() {\r\n  print(\"crlf\");\r\n}\r\n");
    assert_eq!(out, "crlf\n");
}
