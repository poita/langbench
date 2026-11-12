//! Tests of the command-line binary's I/O contract.

use std::io::Write;
use std::process::{Command, Stdio};

fn run(input: &str) -> (String, bool) {
    let mut child = Command::new(env!("CARGO_BIN_EXE_template"))
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .expect("spawn");
    child.stdin.take().unwrap().write_all(input.as_bytes()).unwrap();
    let out = child.wait_with_output().unwrap();
    (String::from_utf8(out.stdout).unwrap(), out.status.success())
}

#[test]
fn prints_rendering_and_newline() {
    let (out, ok) = run("{\"name\": \"Ada\"}\n--\n=== main\nHello {{ name }}!");
    assert!(ok);
    assert_eq!(out, "Hello Ada!\n");
}

#[test]
fn empty_template_prints_one_newline() {
    assert_eq!(run("{}\n--\n=== main\n\n"), ("\n".to_string(), true));
}

#[test]
fn trailing_newline_in_body_needs_blank_line() {
    assert_eq!(run("{}\n--\n=== main\nx\n\n").0, "x\n\n");
    assert_eq!(run("{}\n--\n=== main\nx\n").0, "x\n");
}

#[test]
fn errors_are_one_line_with_exit_zero() {
    for (tpl, kind) in [
        ("{{ x", "syntax"),
        ("{{ 1|nope }}", "filter"),
        ("{{ x }}", "undefined"),
        ("{% include 'q' %}", "template"),
        ("{{ 1 / 0 }}", "type"),
    ] {
        let (out, ok) = run(&format!("{{}}\n--\n=== main\nbefore {tpl}"));
        assert!(ok);
        assert_eq!(out, format!("error: {kind}\n"));
    }
}

#[test]
fn worked_example_from_the_spec() {
    let input = "{\"user\": {\"name\": \"Ada\", \"tags\": [\"x\", \"y\"]}, \"n\": 3}\n--\n=== main\nHi {{ user.name|upper }}!\n{% for t in user.tags -%}\n  {{ loop.index }}. {{ t }}\n{% endfor -%}\n{% if n > 2 and user.tags|length == 2 %}big{% elif n %}small{% else %}none{% endif %} {{ 7 / 2 }} {{ 7 // 2 }} {{ [n, \"s\"] }}";
    assert_eq!(run(input).0, "Hi ADA!\n1. x\n2. y\nbig 3.5 3 [3, 's']\n");
}
