//! Tests of the command-line binary.

use std::io::Write;
use std::process::{Command, Stdio};

fn run(input: &[u8]) -> (bool, Vec<u8>) {
    let mut child = Command::new(env!("CARGO_BIN_EXE_qrcode"))
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    child.stdin.take().unwrap().write_all(input).unwrap();
    let out = child.wait_with_output().unwrap();
    (out.status.success(), out.stdout)
}

#[test]
fn output_format_and_multiple_queries() {
    let (ok, out) = run(b"M 0 HELLO WORLD\nL auto 01234567");
    assert!(ok);
    let text = String::from_utf8(out).unwrap();
    // Two symbols of 21 rows, each preceded by a header and followed by an empty line.
    let lines: Vec<&str> = text.split('\n').collect();
    assert_eq!(lines[0], "version 1 mask 0");
    assert_eq!(lines[22], "");
    assert_eq!(lines[23], "version 1 mask 3");
    assert_eq!(lines[45], "");
    assert_eq!(
        lines[46], "",
        "text ends with newline after the last empty line"
    );
    assert_eq!(lines.len(), 47);
}

#[test]
fn trailing_newline_is_optional() {
    assert_eq!(run(b"H 5 h\xc3\xa9llo"), run(b"H 5 h\xc3\xa9llo\n"));
}

#[test]
fn malformed_input_fails() {
    let (ok, _) = run(b"Z 0 abc\n");
    assert!(!ok);
}
