//! Tests of the command-line contract.

use std::io::Write;
use std::process::{Command, Stdio};

fn run_cli(input: &str) -> (String, bool) {
    let mut child = Command::new(env!("CARGO_BIN_EXE_jsonschema-cli"))
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    child.stdin.take().unwrap().write_all(input.as_bytes()).unwrap();
    let out = child.wait_with_output().unwrap();
    (String::from_utf8(out.stdout).unwrap(), out.status.success())
}

#[test]
fn prints_one_line_per_test() {
    let (out, ok) = run_cli(
        r#"{"schema":{"type":"integer","minimum":1},
            "tests":[{"description":"a positive integer","data":3},
                     {"description":"zero","data":0},
                     {"description":"a string","data":"3"}]}"#,
    );
    assert!(ok);
    assert_eq!(out, "valid\ninvalid\ninvalid\n");
}

#[test]
fn remotes_and_extra_members() {
    let (out, ok) = run_cli(
        r#"{"extra":1,"schema":{"$ref":"http://x.test/s"},
            "remotes":{"http://x.test/s":{"type":"string"}},
            "tests":[{"description":"d","data":"a"},{"description":"d","data":1}]}"#,
    );
    assert!(ok);
    assert_eq!(out, "valid\ninvalid\n");
}

#[test]
fn empty_test_list_prints_nothing() {
    let (out, ok) = run_cli(r#"{"schema":true,"tests":[]}"#);
    assert!(ok);
    assert_eq!(out, "");
}

#[test]
fn malformed_input_fails() {
    let (out, ok) = run_cli("{not json");
    assert!(!ok);
    assert_eq!(out, "");
}
