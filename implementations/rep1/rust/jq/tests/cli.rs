//! End-to-end tests of the command-line tool.

use std::io::Write;
use std::process::{Command, Stdio};

fn cli(stdin: &str) -> (String, i32) {
    let mut child = Command::new(env!("CARGO_BIN_EXE_jqlite"))
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    child.stdin.take().unwrap().write_all(stdin.as_bytes()).unwrap();
    let out = child.wait_with_output().unwrap();
    (String::from_utf8(out.stdout).unwrap(), out.status.code().unwrap())
}

#[test]
fn prints_each_result_on_its_own_line() {
    let (out, code) = cli(".[] | . * 2\n[1,\n 2]\n");
    assert_eq!((out.as_str(), code), ("2\n4\n", 0));
}

#[test]
fn prints_error_after_partial_output() {
    let (out, code) = cli("[(1,2) + (10,20)], {a:(1,2)}, (.[] | .a.b?)\n[{\"a\":{\"b\":1}},{\"a\":5},3]\n");
    assert_eq!(code, 0);
    assert_eq!(out, "[11,12,21,22]\n{\"a\":1}\n{\"a\":2}\n1\nerror\n");
}

#[test]
fn empty_output_for_empty_filter_result() {
    let (out, code) = cli("empty\nnull\n");
    assert_eq!((out.as_str(), code), ("", 0));
}

#[test]
fn scalar_document_without_trailing_newline() {
    let (out, _) = cli(".\n  42  ");
    assert_eq!(out, "42\n");
}
