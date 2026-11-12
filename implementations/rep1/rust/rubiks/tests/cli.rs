//! Tests of the command-line tool's I/O contract.

use rubiks::{parse_moves, CubieCube};
use std::io::Write;
use std::process::{Command, Stdio};

fn run(input: &[u8]) -> (String, bool) {
    let mut child = Command::new(env!("CARGO_BIN_EXE_rubiks"))
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    child.stdin.take().unwrap().write_all(input).unwrap();
    let out = child.wait_with_output().unwrap();
    (String::from_utf8(out.stdout).unwrap(), out.status.success())
}

/// Checks that `output` has one valid short solution per scramble line.
fn check(input: &str, output: &str) {
    let scrambles: Vec<&str> = {
        let mut v: Vec<&str> = input.split('\n').collect();
        if input.ends_with('\n') {
            v.pop();
        }
        v
    };
    let solutions: Vec<&str> = output.split_terminator('\n').collect();
    assert_eq!(scrambles.len(), solutions.len(), "line count");
    for (s, sol) in scrambles.iter().zip(solutions) {
        let sol_moves = parse_moves(sol).unwrap();
        assert!(sol_moves.len() <= 52);
        assert_eq!(sol.split(' ').filter(|t| !t.is_empty()).count(), sol_moves.len());
        let c = CubieCube::SOLVED
            .apply_all(&parse_moves(s).unwrap())
            .apply_all(&sol_moves);
        assert!(c.is_solved(), "scramble {s:?} -> {sol:?}");
    }
}

#[test]
fn single_move() {
    let (out, ok) = run(b"R\n");
    assert!(ok);
    check("R\n", &out);
}

#[test]
fn empty_lines_and_trailing_newline_rules() {
    let (out, ok) = run(b"F R U'\n\nR U R' U'\n");
    assert!(ok);
    check("F R U'\n\nR U R' U'\n", &out);
    assert_eq!(out.split('\n').nth(1), Some(""));

    // No trailing newline: the last line still counts.
    let (out, _) = run(b"R");
    check("R", &out);
    assert_eq!(out.matches('\n').count(), 1);

    // A blank last line is a (solved) scramble of its own.
    let (out, _) = run(b"R\n\n");
    assert_eq!(out.matches('\n').count(), 2);
    assert!(out.ends_with("\n\n"));

    // A single empty line is one empty scramble.
    let (out, _) = run(b"\n");
    assert_eq!(out, "\n");
}

#[test]
fn superflip_and_many_lines() {
    let input = "U R2 F B R B2 R U2 L B2 R U' D' R2 F R' L B2 U2 F2\nR2 L2 U2 D2 F2 B2\nD B' L2\n";
    let (out, ok) = run(input.as_bytes());
    assert!(ok);
    check(input, &out);
}

#[test]
fn long_scramble() {
    let mut s = String::new();
    let toks = ["R", "U'", "F2", "L", "D'", "B2"];
    for i in 0..1000 {
        if i > 0 {
            s.push(' ');
        }
        s.push_str(toks[(i * 7 + i / 3) % 6]);
    }
    s.push('\n');
    let (out, ok) = run(s.as_bytes());
    assert!(ok);
    check(&s, &out);
}

#[test]
fn bad_token_fails() {
    let (_, ok) = run(b"R X\n");
    assert!(!ok);
}
