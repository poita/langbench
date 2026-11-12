//! End-to-end tests of the command-line binary.

use std::io::Write;
use std::process::{Command, Stdio};

fn run(input: &str) -> String {
    let mut child = Command::new(env!("CARGO_BIN_EXE_bigint"))
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
fn spec_examples() {
    assert_eq!(run("12 + 30\n5 - 7\n-7 / 2\n-7 % 2\n"), "42\n-2\n-3\n-1\n");
    assert_eq!(
        run("-0 + 0\n007 cmp 7\n-5 * 0\n99999999999999999999 + 1\n2 ^ 10\n0 ^ 0\n"),
        "0\n0\n0\n100000000000000000000\n1024\n1\n"
    );
    assert_eq!(
        run("1 / 0\n0 % 0\n2 ^ -1\n5 ^ -0\n5 / -0\n-0 ^ -00\n-3 cmp -2"),
        "error\nerror\nerror\n1\nerror\n1\n-1\n"
    );
}

#[test]
fn empty_input_prints_nothing() {
    assert_eq!(run(""), "");
}

#[test]
fn large_power() {
    let out = run("3 ^ 5000\n");
    assert_eq!(out.trim_end().len(), 2386);
    assert!(out.starts_with("403899762978"));
    assert!(out.trim_end().ends_with("998276100001"));
}
