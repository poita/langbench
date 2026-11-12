//! End-to-end tests of the command-line binary.

use std::io::Write;
use std::process::{Command, Stdio};

fn run(input: &[u8]) -> (Vec<u8>, bool) {
    let mut child = Command::new(env!("CARGO_BIN_EXE_json-canon"))
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    child.stdin.take().unwrap().write_all(input).unwrap();
    let out = child.wait_with_output().unwrap();
    (out.stdout, out.status.success())
}

#[test]
fn valid_document() {
    assert_eq!(run(b" { \"b\" : 1E2 , \"a\" : [ ] } "), (b"{\"a\":[],\"b\":1e2}\n".to_vec(), true));
}

#[test]
fn invalid_document_exits_zero() {
    assert_eq!(run(b"[1,]"), (b"invalid\n".to_vec(), true));
    assert_eq!(run(b""), (b"invalid\n".to_vec(), true));
    assert_eq!(run(b"\xEF\xBB\xBF1"), (b"invalid\n".to_vec(), true));
}

#[test]
fn unclosed_deep_input() {
    assert_eq!(run("[".repeat(100_000).as_bytes()), (b"invalid\n".to_vec(), true));
}
