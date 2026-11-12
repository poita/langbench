//! End-to-end tests of the command-line binary, using the examples from the spec.

use std::io::Write;
use std::process::{Command, Stdio};

fn run(input: &str) -> (String, bool) {
    let mut child = Command::new(env!("CARGO_BIN_EXE_chess-perft"))
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    child.stdin.take().unwrap().write_all(input.as_bytes()).unwrap();
    let out = child.wait_with_output().unwrap();
    (String::from_utf8(out.stdout).unwrap(), out.status.success())
}

#[test]
fn perft_queries() {
    let input = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1 1\n\
                 rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1 3\n\
                 r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1 0";
    // No trailing newline on the input is allowed.
    assert_eq!(run(input), ("20\n8902\n1\n".to_string(), true));
}

#[test]
fn divide_with_promotions() {
    let (out, ok) = run("8/P1k5/K7/8/8/8/8/8 w - - 0 1 divide 1\n");
    assert!(ok);
    assert_eq!(out, "a6a5 1\na6b5 1\na7a8b 1\na7a8n 1\na7a8q 1\na7a8r 1\ntotal 6\n");
}

#[test]
fn divide_sorted_and_stalemate() {
    let (out, _) = run("r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1 divide 2\n");
    assert!(out.starts_with("a1a2 25\na1a3 24\n"));
    assert!(out.contains("e1c1 23\ne1d1 26\n"));
    assert!(out.ends_with("h1h8 3\ntotal 568\n"));
    let (out, _) = run("7k/5Q2/6K1/8/8/8/8/8 b - - 0 1 divide 3\n");
    assert_eq!(out, "total 0\n");
}

#[test]
fn empty_input_gives_empty_output() {
    assert_eq!(run(""), (String::new(), true));
}

#[test]
fn malformed_input_fails() {
    assert!(!run("garbage\n").1);
}
