//! End-to-end tests of the command-line binary.

use std::io::Write;
use std::process::{Command, Stdio};

fn run_cli(input: &[u8]) -> (String, String, Option<i32>) {
    let mut child = Command::new(env!("CARGO_BIN_EXE_textbuffer-cli"))
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn textbuffer-cli");
    child.stdin.take().unwrap().write_all(input).unwrap();
    let out = child.wait_with_output().unwrap();
    (
        String::from_utf8(out.stdout).unwrap(),
        String::from_utf8(out.stderr).unwrap(),
        out.status.code(),
    )
}

#[test]
fn prints_document_and_cursors() {
    let (out, err, code) = run_cli(b"2\nhello\nworld\nmove end\ninsert !\nprint\n");
    assert_eq!(out, "hello!\nworld\ncursor 0 6\n--\n");
    assert_eq!(err, "");
    assert_eq!(code, Some(0));
}

#[test]
fn no_print_means_empty_output() {
    let (out, _, code) = run_cli(b"0\ninsert x\n");
    assert_eq!(out, "");
    assert_eq!(code, Some(0));
}

#[test]
fn input_without_final_newline() {
    let (out, _, code) = run_cli(b"1\nab\nprint");
    assert_eq!(out, "ab\ncursor 0 0\n--\n");
    assert_eq!(code, Some(0));
}

#[test]
fn bad_command_fails_with_message() {
    let (_, err, code) = run_cli(b"0\nfrobnicate\n");
    assert_eq!(code, Some(1));
    assert!(err.contains("line 2"), "{err}");
}
