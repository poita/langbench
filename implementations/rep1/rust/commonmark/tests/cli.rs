//! Tests of the command-line contract: Markdown on stdin, HTML on stdout.

use std::io::Write;
use std::process::{Command, Stdio};

fn run(input: &[u8]) -> (Vec<u8>, bool) {
    let mut child = Command::new(env!("CARGO_BIN_EXE_commonmark"))
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    child.stdin.take().unwrap().write_all(input).unwrap();
    let out = child.wait_with_output().unwrap();
    (out.stdout, out.status.success())
}

#[test]
fn empty_input_gives_empty_output() {
    let (out, ok) = run(b"");
    assert!(ok);
    assert!(out.is_empty());
}

#[test]
fn converts_stdin_to_stdout() {
    let (out, ok) = run(b"# Hi\n\n*there*");
    assert!(ok);
    assert_eq!(String::from_utf8(out).unwrap(), "<h1>Hi</h1>\n<p><em>there</em></p>\n");
}

#[test]
fn utf8_passes_through() {
    let (out, ok) = run("héllo ✓\n".as_bytes());
    assert!(ok);
    assert_eq!(String::from_utf8(out).unwrap(), "<p>héllo ✓</p>\n");
}

#[test]
fn large_input_is_fast_and_deep_nesting_is_safe() {
    let mut doc = String::new();
    for _ in 0..300 {
        doc.push_str("> ");
    }
    doc.push_str("deep\n");
    doc.push_str(&"*a ".repeat(50_000));
    doc.push('\n');
    let (out, ok) = run(doc.as_bytes());
    assert!(ok);
    assert!(out.starts_with(b"<blockquote>\n"));
}
