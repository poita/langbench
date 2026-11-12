//! End-to-end tests of the command-line binary.

use std::io::Write;
use std::process::{Command, Stdio};

fn run_cli(input: &str) -> (String, bool) {
    let mut child = Command::new(env!("CARGO_BIN_EXE_ordered-map"))
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
fn example_2() {
    let input = "14\ninsert 10 a\ninsert 20 b\ninsert 30 c\nfloor 25\nceil 25\nfloor 10\n\
                 ceil 10\nsucc 10\npred 10\nsucc 30\nrank 20\nrank 21\nselect 2\nselect 3\n";
    let (out, ok) = run_cli(input);
    assert!(ok);
    assert_eq!(out, "ok\nok\nok\n20\n30\n10\n10\n20\nmissing\nmissing\n1\n2\n30\nmissing\n");
}

#[test]
fn example_3_extreme_keys() {
    let input = "9\ninsert -9223372036854775808 lo\ninsert 9223372036854775807 hi\n\
                 insert 0 zero\nsucc 9223372036854775807\npred -9223372036854775808\n\
                 floor -9223372036854775807\nceil 1\n\
                 range -9223372036854775808 9223372036854775807\ndelete 0";
    let (out, ok) = run_cli(input);
    assert!(ok);
    assert_eq!(
        out,
        "ok\nok\nok\nmissing\nmissing\n-9223372036854775808\n9223372036854775807\n\
         -9223372036854775808 0 9223372036854775807\nok\n"
    );
}

#[test]
fn values_are_opaque() {
    let (out, _) = run_cli("5\ninsert 1 missing\nget 1\ninsert 2 \"'`\\<>|{}#\nget 2\nget 3\n");
    assert_eq!(out, "ok\nmissing\nok\n\"'`\\<>|{}#\nmissing\n");
}

#[test]
fn zero_commands() {
    let (out, ok) = run_cli("0\n");
    assert!(ok);
    assert_eq!(out, "");
}

#[test]
fn large_sorted_workload_is_fast() {
    let n = 200_000;
    let mut input = format!("{}\n", n * 2);
    for k in 0..n {
        input.push_str(&format!("insert {k} v\n"));
    }
    for k in (0..n).rev() {
        input.push_str(&format!("delete {k}\n"));
    }
    let (out, ok) = run_cli(&input);
    assert!(ok);
    assert_eq!(out.lines().count(), n * 2);
}

#[test]
fn malformed_input_fails() {
    let (_, ok) = run_cli("1\nfrobnicate\n");
    assert!(!ok);
}
