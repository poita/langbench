"""Compile-time diagnostics: kind and exact position, pass order."""

import pytest

from conftest import main_module


@pytest.mark.parametrize(
    "src, expected",
    [
        # pass 0 / 1 / 2
        ("fn main() {}", "bad-module at 1:1"),
        ("@module main\nfn main() { 0x }", "bad-token at 1:13"),
        ("@module main\nfn main() { let x = 1 }", "parse at 1:23"),
        # example 15: parsing beats checking, positions are module-local
        ("@module main\nfn main() {\n    let x: Int = \"s\";\n}\n@module other\nfn f( {\n}\n", "parse at 1:7"),
        # pass 3
        ("@module main\nfn f() {}", "no-main at 1:1"),
        ("@module main\nfn main(x: Int) {}", "no-main at 1:1"),
        ("@module main\nstruct Int {}\nfn main() {}", "reserved-name at 1:8"),
        ("@module main\nfn f() {}\nfn f() {}\nfn main() {}", "dup-name at 2:4"),
        ("@module main\nuse nope;\nfn main() {}", "unknown-module at 1:5"),
        ("@module main\nfn f(x: Nope) {}\nfn main() {}", "unknown-type at 1:9"),
        ("@module main\nstruct S<T> {}\nfn f(x: S) {}\nfn main() {}", "arity-type at 2:9"),
        ("@module main\nfn f(x: #[Float: Int]) {}\nfn main() {}", "bad-key-type at 1:9"),
        ("@module main\nimpl Eq for Int {}\nfn main() {}", "builtin-trait-impl at 1:1"),
        ("@module main\ntrait T { fn m(self); }\nimpl T for [Int] { fn m(self) {} }\nfn main() {}", "bad-impl-head at 2:12"),
        ("@module main\ntrait T { fn m(self); }\nimpl<A> T for Int { fn m(self) {} }\nfn main() {}", "unused-param at 2:6"),
        ("@module main\ntrait T { fn m(self); }\nimpl T for Int { fn m(self) {} }\nimpl T for Int { fn m(self) {} }\nfn main() {}", "dup-impl at 3:1"),
        ("@module main\ntrait T { fn m(self); }\nimpl T for Int { }\nfn main() {}", "missing-method at 2:1"),
        ("@module main\ntrait T { fn m(self); }\nimpl T for Int { fn m(self) {} fn z(self) {} }\nfn main() {}", "extra-method at 2:35"),
        ("@module main\ntrait T { fn m(self) -> Int; }\nimpl T for Int { fn m(self) -> Str { \"\" } }\nfn main() {}", "sig-mismatch at 2:21"),
        # pass 4 -- bodies
        ("@module main\nfn f() -> Int { let x = 1; }\nfn main() {}", "missing-return at 1:1"),
    ],
)
def test_program_level(run, src, expected):
    assert run(src) == f"error: {expected}\n"


@pytest.mark.parametrize(
    "body, expected",
    [
        ('let n: Int = 1; print(n + "x");', "type-mismatch at 3:27"),
        ("let x = 1; x = 2;", "assign-immutable at 3:12"),
        ("var xs = [];", "cannot-infer at 3:10"),
        ("let x = None;", "cannot-infer at 3:9"),
        ("print(showInt(len([1])));", "unknown-name at 3:15"),
        ("let f = |x| x;", "cannot-infer at 3:10"),
        ("var x = 1; let f = || { x = 2; };", "assign-captured at 3:25"),
        ("for i in 0 .. 3 { let f = || { break; }; }", "break-outside at 3:32"),
        ("let t = (1, 2); let (a, b, c) = t;", "type-mismatch at 3:21"),
        ("let o = Some(1); let Some(v) = o;", "refutable-pattern at 3:22"),
        ("match 3 { _ -> print(\"a\"), 1 -> print(\"b\"), }", "unreachable at 3:28"),
        ("match 3 { 1 -> print(\"a\"), }", "non-exhaustive at 3:1"),
        ("let a = [1] < [2];", "not-ord at 3:9"),
        ("let f = |x: Int| x; print(showBool(f == f));", "not-eq at 3:36"),
        ("let x = Some;", "bad-value-ref at 3:9"),
        ("let x = 5; x();", "not-callable at 3:12"),
        ("let x = foo::bar;", "unknown-module at 3:9"),
        ("let x = self;", "self-outside at 3:9"),
        ("let s = \"abc\"; s[0] = 'x';", "bad-target at 3:16"),
        ("let a = 1 < 2 < 3;", "parse at 3:15"),
        ("let m = #[1.5: \"x\"];", "bad-key-type at 3:11"),
        ("let x = unwrap(Some(1), 2);", "arity at 3:9"),
    ],
)
def test_body_errors(run_main, body, expected):
    # the body starts on line 3 of the module (line 1 is blank, 2 is `fn main`)
    assert run_main(body) == f"error: {expected}\n"


def test_ambiguous_method(run):
    src = (
        "@module main\ntrait A { fn go(self) -> Int; }\ntrait B { fn go(self) -> Int; }\n"
        "impl A for Int { fn go(self) -> Int { 1 } }\nimpl B for Int { fn go(self) -> Int { 2 } }\n"
        "fn main() { print(showInt(3.go())); print(showInt(A::go(3))); }\n"
    )
    assert run(src) == "error: ambig-method at 5:29\n"


def test_unsatisfied_bound_names_the_callee(run):
    src = (
        "@module main\ntrait Area { fn area(self) -> Int; }\nstruct Sq { s: Int }\n"
        "fn total<T: Area>(xs: [T]) -> Int { 0 }\nfn main() { print(showInt(total([Sq.{ s: 3 }]))); }\n"
    )
    assert run(src) == "error: unsatisfied-bound at 4:27\n"


def test_not_public_and_unknown_member(run):
    src = "@module main\nuse m;\nfn main() { m::f(); }\n@module m\nfn f() {}\n"
    assert run(src) == "error: not-public at 2:16\n"
    src = "@module main\nuse m;\nfn main() { m::g(); }\n@module m\npub fn f() {}\n"
    assert run(src) == "error: unknown-name at 2:16\n"


def test_missing_return_is_reported_after_body_errors(run):
    src = main_module("", "fn f() -> Int { let x: Int = \"a\"; }")
    assert run(src) == "error: type-mismatch at 1:30\n"
