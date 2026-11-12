//! End-to-end tests of the command-line binary.

use std::io::Write;
use std::process::{Command, Stdio};

fn run_cli(input: &str) -> String {
    let mut child = Command::new(env!("CARGO_BIN_EXE_bigint"))
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .expect("spawn bigint");
    child.stdin.take().unwrap().write_all(input.as_bytes()).unwrap();
    let out = child.wait_with_output().unwrap();
    assert!(out.status.success());
    String::from_utf8(out.stdout).unwrap()
}

#[test]
fn empty_input_prints_nothing() {
    assert_eq!(run_cli(""), "");
}

#[test]
fn example_two() {
    let input = "-0 + 0\n007 cmp 7\n-5 * 0\n99999999999999999999 + 1\n2 ^ 10\n0 ^ 0\n";
    let expected = "0\n0\n0\n100000000000000000000\n1024\n1\n";
    assert_eq!(run_cli(input), expected);
}

#[test]
fn example_three_without_final_newline() {
    let input = "1 / 0\n0 % 0\n2 ^ -1\n-123456789012345678901234567890 * 987654321098765432109876543210\n1000000000000000000000000000000 - 1\n-3 cmp -2";
    let expected = "error\nerror\nerror\n-121932631137021795226185032733622923332237463801111263526900\n999999999999999999999999999999\n-1\n";
    assert_eq!(run_cli(input), expected);
}

#[test]
fn never_prints_negative_zero() {
    assert_eq!(run_cli("-7 % 7\n-1 / 2\n-0 - 0\n0 * -9\n-0 cmp 0\n"), "0\n0\n0\n0\n0\n");
}
