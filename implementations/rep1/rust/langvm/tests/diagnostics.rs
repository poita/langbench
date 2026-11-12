//! Compile-time diagnostics: kinds, positions and pass order.

mod common;
use common::*;

fn diag(body: &str, expected: &str) {
    assert_eq!(run_main(body), format!("{}\n", expected), "program:\n{}", body);
}

#[test]
fn module_stream() {
    assert_eq!(run(""), "error: bad-module at 1:1\n");
    assert_eq!(run("fn main() {}\n"), "error: bad-module at 1:1\n");
    assert_eq!(run("@module main \nfn main() {}\n"), "error: bad-module at 1:1\n");
    assert_eq!(run("@module main\n@modulex\n"), "error: bad-module at 2:1\n");
    assert_eq!(run("@module main\n@module main\n"), "error: dup-module at 2:1\n");
    assert_eq!(run("@module main\nfn f() {}\n"), "error: no-main at 1:1\n");
    assert_eq!(run("@module main\nfn main() -> Int { 1 }\n"), "error: no-main at 1:1\n");
    assert_eq!(run("@module main\nuse nope;\nfn main() {}\n"), "error: unknown-module at 1:5\n");
}

#[test]
fn lexical_errors() {
    diag("fn main() { let x = 9223372036854775808; }", "error: int-range at 1:21");
    diag("fn main() { let c = '\\u{110000}'; }", "error: bad-escape at 1:22");
    diag("fn main() { let c = 'ab'; }", "error: unterminated at 1:21");
    diag("fn main() { let s = \"abc; }", "error: unterminated at 1:21");
    diag("fn main() { /* never closed", "error: unterminated at 1:13");
    diag("fn main() { let x = 0x; }", "error: bad-token at 1:21");
    diag("fn main() { let é = 1; }", "error: bad-token at 1:17");
    diag("fn main() { let x = #; }", "error: bad-token at 1:21");
}

#[test]
fn parse_errors() {
    diag("fn main() { let x = 1 }", "error: parse at 1:23");
    diag("fn main() { 1 < 2 < 3; }", "error: parse at 1:19");
    diag("fn f(\n", "error: parse at 2:1");
    diag("pub impl X for Int {}", "error: parse at 1:5");
    diag("fn main() { let f = | | 8; }", "error: parse at 1:23");
    diag("struct S<T: Eq> { x: T }", "error: parse at 1:11");
}

#[test]
fn declaration_errors() {
    diag("struct Int { x: Int }\nfn main() {}", "error: reserved-name at 1:8");
    diag("struct A {}\nenum A { X }\nfn main() {}", "error: dup-name at 2:6");
    diag("fn f() {}\nfn f() {}\nfn main() {}", "error: dup-name at 2:4");
    diag("fn f(a: Foo) {}\nfn main() {}", "error: unknown-type at 1:9");
    diag("struct P<T> { x: T }\nfn f(a: P) {}\nfn main() {}", "error: arity-type at 2:9");
    diag("fn f(a: #[Float: Int]) {}\nfn main() {}", "error: bad-key-type at 1:9");
    diag("impl Eq for Int {}\nfn main() {}", "error: builtin-trait-impl at 1:1");
    diag("trait T { fn m(self); }\nimpl T for [Int] { fn m(self) {} }\nfn main() {}", "error: bad-impl-head at 2:12");
    diag("trait T { fn m(self); }\nimpl<A> T for Int { fn m(self) {} }\nfn main() {}", "error: unused-param at 2:6");
    diag("trait T { fn m(self); }\nimpl T for Int { fn m(self) {} }\nimpl T for Int { fn m(self) {} }\nfn main() {}", "error: dup-impl at 3:1");
    diag("trait T { fn m(self); }\nimpl T for Int { }\nfn main() {}", "error: missing-method at 2:1");
    diag("trait T { fn m(self); }\nimpl T for Int { fn m(self) {} fn z(self) {} }\nfn main() {}", "error: extra-method at 2:35");
    diag("trait T { fn m(self) -> Int; }\nimpl T for Int { fn m(self) -> Str { \"\" } }\nfn main() {}", "error: sig-mismatch at 2:21");
}

#[test]
fn type_errors() {
    diag("fn main() {\n    let n: Int = 1;\n    print(n + \"x\");\n}", "error: type-mismatch at 3:15");
    diag("fn main() { let x = None; }", "error: cannot-infer at 1:21");
    diag("fn main() { var xs = []; }", "error: cannot-infer at 1:22");
    diag("fn f() -> Int { let x = 1; }\nfn main() {}", "error: missing-return at 1:1");
    diag("fn f() { 5 }\nfn main() {}", "error: type-mismatch at 1:10");
    diag("fn main() { let x = 1; x = 2; }", "error: assign-immutable at 1:24");
    diag("fn main() { break; }", "error: break-outside at 1:13");
    diag("fn main() { print(1); }", "error: type-mismatch at 1:19");
    diag("fn main() { print(); }", "error: arity at 1:13");
    diag("fn main() { 1(2); }", "error: not-callable at 1:13");
    diag("fn main() { let f = print; }", "error: bad-value-ref at 1:21");
    diag("fn main() { let x = foo; }", "error: unknown-name at 1:21");
    diag("fn main() { for c in 'a' { } }", "error: not-iterable at 1:22");
    diag("fn main() { let t = (1, 2); t.x; }", "error: not-struct at 1:29");
    diag("struct S { a: Int, b: Int }\nfn main() { let s = S.{ a: 1 }; }", "error: missing-field at 2:21");
    diag("fn main() { let f = |x: Int| x; let b = f == f; }", "error: not-eq at 1:41");
    diag("fn main() { let b = (1, 2) < (3, 4); }", "error: not-ord at 1:21");
    diag("fn main() { let v = [1, 2]; v.len(); }", "error: no-method at 1:31");
}

#[test]
fn closures_and_assignment() {
    diag("fn main() { var n = 0; let f = || { n = 1; }; }", "error: assign-captured at 1:37");
    diag("fn main() { for x in [1] { let f = || { break; }; } }", "error: break-outside at 1:41");
    diag("fn main() { let f = |x| x; }", "error: cannot-infer at 1:22");
    diag("fn main() { let s = \"ab\"; s[0] = 'c'; }", "error: bad-target at 1:27");
    diag("fn main() { 1 = 2; }", "error: bad-target at 1:13");
}

#[test]
fn patterns_and_exhaustiveness() {
    diag("enum C { R, G, B }\nfn f(c: C) -> Int {\n    match c {\n        R -> 1,\n        G -> 2,\n    }\n}\nfn main() {}", "error: non-exhaustive at 3:5");
    diag("fn main() {\n    match 3 {\n        _ -> print(\"a\"),\n        1 -> print(\"b\"),\n    }\n}", "error: unreachable at 4:9");
    diag("fn main() { let (a, a) = (1, 2); }", "error: dup-name at 1:21");
    diag("fn main() { match 1.5 { 1.5 -> {} _ -> {} } }", "error: bad-pattern at 1:25");
    diag("fn main() { let 1 = 1; }", "error: refutable-pattern at 1:17");
    diag("fn main() { match [1] { [] -> {} [_, ..] -> {} [..] -> {} } }", "error: unreachable at 1:48");
    diag("fn main() { match [1] { [] -> {} [a] -> {} } }", "error: non-exhaustive at 1:13");
}

#[test]
fn pass_order() {
    // Parsing of every module precedes body checking.
    assert_eq!(
        run("@module main\nfn main() {\n    let x: Int = \"s\";\n}\n@module other\nfn f( {\n}\n"),
        "error: parse at 1:7\n"
    );
    // Item errors precede body errors.
    assert_eq!(
        run("@module main\nfn main() { let x: Int = \"s\"; }\nfn g(a: Nope) {}\n"),
        "error: unknown-type at 2:9\n"
    );
}

#[test]
fn visibility_and_imports() {
    let src = "@module main\nuse util;\nfn main() { print(util::secret()); }\n@module util\nfn secret() -> Str { \"s\" }\n";
    assert_eq!(run(src), "error: not-public at 2:25\n");
    let src = "@module main\nuse util;\nfn main() { print(util::hello()); }\n@module util\npub fn hello() -> Str { \"hi\" }\n";
    assert_eq!(run(src), "hi\n");
    let src = "@module main\nfn main() { print(nope::f()); }\n";
    assert_eq!(run(src), "error: unknown-module at 1:19\n");
}
