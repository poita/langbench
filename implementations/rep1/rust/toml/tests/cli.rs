//! End-to-end tests of the command-line tool.

use std::io::Write;
use std::process::{Command, Stdio};

fn run(input: &[u8]) -> (String, bool) {
    let mut child = Command::new(env!("CARGO_BIN_EXE_tomlcodec"))
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    child.stdin.take().unwrap().write_all(input).unwrap();
    let out = child.wait_with_output().unwrap();
    (String::from_utf8(out.stdout).unwrap(), out.status.success())
}

#[test]
fn decode_valid() {
    let (out, ok) = run(b"decode\na = 'x'\n");
    assert!(ok);
    assert_eq!(out, "{\"a\":{\"type\":\"string\",\"value\":\"x\"}}\n");
}

#[test]
fn decode_invalid_prints_error_and_exits_zero() {
    for doc in [&b"a = \n"[..], b"\xff", b"a = 1\r", b"\xef\xbb\xbfa=1"] {
        let mut input = b"decode\n".to_vec();
        input.extend_from_slice(doc);
        assert_eq!(run(&input), ("error\n".to_string(), true));
    }
}

#[test]
fn encode() {
    let (out, ok) = run(b"encode\n {\"a\" : {\"value\":\"1\", \"type\":\"integer\"}}\n");
    assert!(ok);
    assert_eq!(out, "a = 1\n");
}

#[test]
fn deeply_nested_input_does_not_crash() {
    let n = 300;
    let mut input = b"decode\n".to_vec();
    input.extend(format!("a = {}1{}\n", "[".repeat(n), "]".repeat(n)).bytes());
    let (out, ok) = run(&input);
    assert!(ok);
    assert!(out.starts_with("{\"a\":[[["));
}
