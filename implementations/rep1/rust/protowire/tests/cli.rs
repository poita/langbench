//! Tests that drive the compiled binary the way a user would.

use std::io::Write;
use std::process::{Command, Stdio};

fn run_cli(input: &str) -> (String, i32) {
    let mut child = Command::new(env!("CARGO_BIN_EXE_protowire"))
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    child.stdin.take().unwrap().write_all(input.as_bytes()).unwrap();
    let o = child.wait_with_output().unwrap();
    (String::from_utf8(o.stdout).unwrap(), o.status.code().unwrap())
}

#[test]
fn reads_stdin_writes_stdout() {
    let (out, code) = run_cli("message A { int32 x = 1; }\n--\ndecode A 082a\nencode A {x: 300}\ndecode A 08\n");
    assert_eq!(code, 0);
    assert_eq!(out, "{x: 42}\n08ac02\nerror\n");
}

#[test]
fn malformed_requests_still_exit_zero() {
    let (out, code) = run_cli("message A { int32 x = 1; }\n--\nnonsense\n\ndecode A zz\n");
    assert_eq!(code, 0);
    assert_eq!(out, "error\nerror\nerror\n");
}
