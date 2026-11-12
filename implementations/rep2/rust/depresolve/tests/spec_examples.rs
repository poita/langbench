//! The worked examples from the specification, through the public API.

use depresolve::{resolve_str, UNSATISFIABLE};

#[test]
fn diamond_needs_backtracking() {
    let input = "a 1.0.0: c ^1.0.0\nb 1.0.0: c ~1.2.0\nc 1.1.0:\nc 1.2.5:\nc 1.3.0:\nroot: a *, b *\n";
    assert_eq!(resolve_str(input).unwrap(), "a 1.0.0\nb 1.0.0\nc 1.2.5\n");
}

#[test]
fn first_solution_not_globally_newest() {
    let input = "a 2.0.0: b ~1.0.0\na 1.0.0:\nb 1.0.0:\nb 1.0.5:\nb 1.5.0:\nb 2.0.0:\nroot: a *, b *\n";
    assert_eq!(resolve_str(input).unwrap(), "a 2.0.0\nb 1.0.5\n");
}

#[test]
fn conflicting_majors() {
    let input = "a 1.0.0: c ^1.0.0\nb 1.0.0: c ^2.0.0\nc 1.0.0:\nc 2.0.0:\nroot: a *, b *\n";
    assert_eq!(resolve_str(input).unwrap(), UNSATISFIABLE);
}

#[test]
fn requirement_order_matters() {
    let reg = "a 2.0.0: c ^2.0.0\na 1.0.0: c ^1.0.0\nb 2.0.0: c ^1.0.0\nb 1.0.0: c ^2.0.0\nc 1.0.0:\nc 2.0.0:\n";
    assert_eq!(
        resolve_str(&format!("{reg}root: a *, b *\n")).unwrap(),
        "a 2.0.0\nb 1.0.0\nc 2.0.0\n"
    );
    assert_eq!(
        resolve_str(&format!("{reg}root: b *, a *\n")).unwrap(),
        "a 1.0.0\nb 2.0.0\nc 1.0.0\n"
    );
}

#[test]
fn empty_root_prints_nothing() {
    assert_eq!(resolve_str("root:\n").unwrap(), "");
    assert_eq!(resolve_str("a 1.0.0:\nroot:\n").unwrap(), "");
}

#[test]
fn missing_package_is_unsatisfiable() {
    assert_eq!(resolve_str("root: ghost *\n").unwrap(), UNSATISFIABLE);
}

#[test]
fn cycles_and_self_dependency() {
    let input = "a 1.0.0: b *\nb 1.0.0: a ^1.0.0, b *\nroot: a *\n";
    assert_eq!(resolve_str(input).unwrap(), "a 1.0.0\nb 1.0.0\n");
}

#[test]
fn output_sorted_by_byte_order() {
    let input = "mylib 1.0.0:\nmy-lib 1.0.0:\nmy-lib2 1.0.0:\nroot: mylib *, my-lib2 *, my-lib *\n";
    assert_eq!(
        resolve_str(input).unwrap(),
        "my-lib 1.0.0\nmy-lib2 1.0.0\nmylib 1.0.0\n"
    );
}

#[test]
fn numeric_version_comparison() {
    let input = "a 1.9.0:\na 1.10.0:\na 1.2.0:\nroot: a *\n";
    assert_eq!(resolve_str(input).unwrap(), "a 1.10.0\n");
}

#[test]
fn deep_chain_does_not_overflow_the_stack() {
    let n = 20_000;
    let mut s = String::new();
    for i in 0..n {
        s.push_str(&format!("p{} 1.0.0: p{} *\n", i, i + 1));
    }
    s.push_str(&format!("p{n} 1.0.0:\nroot: p0 *\n"));
    // Names must be [a-z0-9-]; digits are fine after the first letter.
    let out = resolve_str(&s).unwrap();
    assert_eq!(out.lines().count(), n + 1);
}
