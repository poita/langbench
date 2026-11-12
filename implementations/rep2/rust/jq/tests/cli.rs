//! End-to-end tests of the command-line binary.

use std::io::Write;
use std::process::{Command, Stdio};

fn jq(stdin: &str) -> (String, bool) {
    let mut child = Command::new(env!("CARGO_BIN_EXE_jq"))
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    child.stdin.take().unwrap().write_all(stdin.as_bytes()).unwrap();
    let out = child.wait_with_output().unwrap();
    (String::from_utf8(out.stdout).unwrap(), out.status.success())
}

#[test]
fn prints_each_result_on_its_own_line() {
    let (out, ok) = jq(".[]\n[1,\"a\",{\"k\":[true,null]}]\n");
    assert!(ok);
    assert_eq!(out, "1\n\"a\"\n{\"k\":[true,null]}\n");
}

#[test]
fn error_line_follows_partial_output_and_exit_is_zero() {
    let (out, ok) = jq("(.[] | .a.b?)\n[{\"a\":{\"b\":1}},{\"a\":5},3]\n");
    assert!(ok);
    assert_eq!(out, "1\nerror\n");
}

#[test]
fn no_results_prints_nothing() {
    let (out, ok) = jq("empty\nnull");
    assert!(ok);
    assert_eq!(out, "");
}

#[test]
fn multiline_document() {
    let (out, _) = jq(".a\n  {\n \"a\" : [ 1 ,\r\n 2 ]\n}\n");
    assert_eq!(out, "[1,2]\n");
}

#[test]
fn spec_example_pipeline() {
    let (out, _) = jq(".users | map(select(.age >= 30 and .active)) | sort_by(.age) | reverse | map({name, age})\n{\"users\":[{\"name\":\"ann\",\"age\":31,\"active\":true},{\"name\":\"bob\",\"age\":45,\"active\":false},{\"name\":\"cy\",\"age\":30,\"active\":true},{\"name\":\"di\",\"age\":52,\"active\":true},{\"name\":\"ed\",\"age\":29,\"active\":true},{\"name\":\"flo\",\"age\":31,\"active\":true}]}\n");
    assert_eq!(out, "[{\"name\":\"di\",\"age\":52},{\"name\":\"flo\",\"age\":31},{\"name\":\"ann\",\"age\":31},{\"name\":\"cy\",\"age\":30}]\n");
}
