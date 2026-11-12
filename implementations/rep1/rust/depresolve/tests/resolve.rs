//! Integration tests: the examples from the specification plus edge cases.

use depresolve::{parse_input, resolve, Range, Registry, Requirement, Version};

fn run(text: &str) -> String {
    let input = parse_input(text).unwrap();
    match resolve(&input.registry, &input.root) {
        Some(s) => s.to_string(),
        None => "unsatisfiable\n".to_string(),
    }
}

#[test]
fn diamond_needs_backtracking() {
    let out = run("a 1.0.0: c ^1.0.0\nb 1.0.0: c ~1.2.0\nc 1.1.0:\nc 1.2.5:\nc 1.3.0:\nroot: a *, b *\n");
    assert_eq!(out, "a 1.0.0\nb 1.0.0\nc 1.2.5\n");
}

#[test]
fn first_solution_not_globally_newest() {
    let out = run("a 2.0.0: b ~1.0.0\na 1.0.0:\nb 1.0.0:\nb 1.0.5:\nb 1.5.0:\nb 2.0.0:\nroot: a *, b *\n");
    assert_eq!(out, "a 2.0.0\nb 1.0.5\n");
}

#[test]
fn conflicting_majors() {
    let out = run("a 1.0.0: c ^1.0.0\nb 1.0.0: c ^2.0.0\nc 1.0.0:\nc 2.0.0:\nroot: a *, b *\n");
    assert_eq!(out, "unsatisfiable\n");
}

#[test]
fn requirement_order_matters() {
    let reg = "a 2.0.0: c ^2.0.0\na 1.0.0: c ^1.0.0\nb 2.0.0: c ^1.0.0\nb 1.0.0: c ^2.0.0\nc 1.0.0:\nc 2.0.0:\n";
    assert_eq!(run(&format!("{reg}root: a *, b *\n")), "a 2.0.0\nb 1.0.0\nc 2.0.0\n");
    assert_eq!(run(&format!("{reg}root: b *, a *\n")), "a 1.0.0\nb 2.0.0\nc 1.0.0\n");
}

#[test]
fn empty_root_gives_empty_output() {
    assert_eq!(run("a 1.0.0:\nroot:\n"), "");
}

#[test]
fn unknown_package_is_unsatisfiable() {
    assert_eq!(run("root: ghost *\n"), "unsatisfiable\n");
    assert_eq!(run("a 1.0.0: ghost *\nroot: a *\n"), "unsatisfiable\n");
}

#[test]
fn unchosen_versions_requirements_are_irrelevant() {
    // a 2.0.0 needs a missing package, so the search falls back to a 1.0.0.
    assert_eq!(run("a 2.0.0: ghost *\na 1.0.0:\nroot: a *\n"), "a 1.0.0\n");
}

#[test]
fn cycles_and_self_requirements() {
    let out = run("a 1.0.0: b *\nb 1.0.0: a *, b 1.0.0\nroot: a *\n");
    assert_eq!(out, "a 1.0.0\nb 1.0.0\n");
}

#[test]
fn chronological_backtracking_hits_unrelated_package() {
    // y's requirement `x 1.0.0` fails against x 2.0.0; the most recent choice
    // with an alternative is z (unrelated), but z 1.0.0 does not help, so x moves.
    let out = run(
        "x 2.0.0:\nx 1.0.0:\nz 2.0.0:\nz 1.0.0:\ny 1.0.0: x 1.0.0\nroot: x *, z *, y *\n",
    );
    assert_eq!(out, "x 1.0.0\ny 1.0.0\nz 2.0.0\n");
}

#[test]
fn output_sorted_by_byte_order() {
    let out = run("mylib 1.0.0:\nmy-lib2 1.0.0:\nmy-lib 1.0.0:\nroot: mylib *, my-lib2 *, my-lib *\n");
    assert_eq!(out, "my-lib 1.0.0\nmy-lib2 1.0.0\nmylib 1.0.0\n");
}

#[test]
fn numeric_version_comparison() {
    assert_eq!(run("a 1.9.0:\na 1.10.0:\nroot: a *\n"), "a 1.10.0\n");
}

#[test]
fn empty_comparator_range() {
    assert_eq!(run("a 1.0.0:\nroot: a >=2.0.0 <1.0.0\n"), "unsatisfiable\n");
}

#[test]
fn deep_chain_does_not_overflow_the_stack() {
    let n = 20_000;
    let mut text = String::new();
    for i in 0..n {
        text.push_str(&format!("p{} 1.0.0: p{} *\n", name(i), name(i + 1)));
    }
    text.push_str(&format!("p{} 1.0.0:\nroot: p{} *\n", name(n), name(0)));
    let out = run(&text);
    assert_eq!(out.lines().count(), n + 1);
}

fn name(i: usize) -> String {
    // letters only, so it is a valid package name
    let mut s = String::new();
    let mut i = i;
    loop {
        s.push((b'a' + (i % 26) as u8) as char);
        i /= 26;
        if i == 0 {
            break;
        }
    }
    s
}

#[test]
fn exponential_failure_is_enumerated() {
    // Ten packages with two versions each, then an unsatisfiable requirement.
    let mut text = String::new();
    for i in 0..10 {
        text.push_str(&format!("p{} 2.0.0:\np{} 1.0.0:\n", name(i), name(i)));
    }
    text.push_str("root:");
    for i in 0..10 {
        text.push_str(&format!("{} p{} *", if i == 0 { "" } else { "," }, name(i)));
    }
    text.push_str(", ghost *\n");
    assert_eq!(run(&text), "unsatisfiable\n");
}

#[test]
fn library_api_builds_registries() {
    let mut reg = Registry::new();
    reg.add("lib", Version::new(1, 0, 0), vec![]);
    reg.add("lib", Version::new(1, 2, 0), vec![]);
    reg.add(
        "app",
        Version::new(0, 1, 0),
        vec![Requirement::new("lib", "^1.0.0".parse::<Range>().unwrap())],
    );
    let root = vec![Requirement::new("app", Range::ANY)];
    let sol = resolve(&reg, &root).unwrap();
    assert_eq!(sol.get("lib"), Some(Version::new(1, 2, 0)));
    assert_eq!(sol.get("app"), Some(Version::new(0, 1, 0)));
    assert_eq!(sol.get("nope"), None);
    assert_eq!(sol.len(), 2);
}
