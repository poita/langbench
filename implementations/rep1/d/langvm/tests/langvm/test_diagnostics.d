/// Tests for the diagnostics: one expected line per program.
module langvm.test_diagnostics;

import langvm;
import langvm.helpers;

unittest
{
    // pass 0 and pass order
    assert(runSource("").stdout == "error: bad-module at 1:1\n");
    assert(runSource("@module main\nfn main() { let x: Int = \"s\"; }\n@module other\nfn f( {\n}\n").stdout
            == "error: parse at 1:7\n");
    assert(runSource("@module other\nfn main() {}\n").stdout == "error: no-main at 1:1\n");
}

unittest
{
    expectMain("fn main() {\n    let n: Int = 1;\n    print(n + \"x\");\n}", "error: type-mismatch at 3:15\n");
    expectMain("enum Colour { Red, Green, Blue }\nfn name(c: Colour) -> Str {\n    match c {\n        Red -> \"red\",\n"
            ~ "        Green -> \"green\",\n    }\n}\nfn main() { print(name(Blue)); }", "error: non-exhaustive at 3:5\n");
    expectMain("trait Area { fn area(self) -> Int; }\nstruct Sq { s: Int }\nfn total<T: Area>(xs: [T]) -> Int { 0 }\n"
            ~ "fn main() {\n    print(showInt(total([Sq.{ s: 3 }])));\n}", "error: unsatisfied-bound at 5:19\n");
}

unittest
{
    expectBody("let x = 1;\nx = 2;", "error: assign-immutable at 3:1\n");
    expectBody("var xs = [];", "error: cannot-infer at 2:10\n");
    expectBody("match 3 {\n _ -> print(\"a\"),\n 1 -> print(\"b\"),\n }", "error: unreachable at 4:2\n");
    expectMain("fn f() -> Int {\n    let x = 1;\n}\nfn main() { print(showInt(f())); }", "error: missing-return at 1:1\n");
    expectBody("let t = (1, \"two\");\nlet f = |x: Int| x;\nprint(showBool(f == f));", "error: not-eq at 4:16\n");
    expectBody("for c in 'a' { }", "error: not-iterable at 2:10\n");
    expectBody("let m = #[1.5: \"x\"];", "error: bad-key-type at 2:11\n");
    expectBody("print(len([1]));", "error: unknown-name at 2:7\n");
    expectBody("break;", "error: break-outside at 2:1\n");
    expectBody("let x = 1 < 2 < 3;", "error: parse at 2:15\n");
}

unittest
{
    expectMain("struct S { a: Int, b: Int }\nfn main() { let s = S.{ a: 1 }; }", "error: missing-field at 2:21\n");
    expectMain("struct S { a: Int }\nfn main() { let s = S.{ a: 1, a: 2 }; }", "error: dup-field at 2:31\n");
    expectMain("struct S { a: Int }\nfn main() { let s = S.{ a: 1, z: 2 }; }", "error: unknown-field at 2:31\n");
    expectMain("fn f(x: Int) {}\nfn main() { f(1, 2); }", "error: arity at 2:13\n");
    expectMain("fn main() { let x = 3; x(1); }", "error: not-callable at 1:24\n");
    expectMain("fn g() {}\nfn main() { let x = g; }", "error: bad-value-ref at 2:21\n");
    expectMain("fn main() { var s = \"ab\"; s[0] = 'c'; }", "error: bad-target at 1:27\n");
    expectMain("fn main() { let x = (1, 2, 3, 4, 5, 6, 7, 8, 9); }", "error: bad-arity at 1:21\n");
}

unittest
{
    expectMain("struct Int {}\nfn main() {}", "error: reserved-name at 1:8\n");
    expectMain("fn f() {}\nfn f() {}\nfn main() {}", "error: dup-name at 2:4\n");
    expectMain("fn main() { let x: Nope = 1; }", "error: unknown-type at 1:20\n");
    expectMain("fn f<T: Nope>() {}\nfn main() {}", "error: unknown-trait at 1:9\n");
    expectMain("struct P<T> { a: T }\nfn f(p: P) {}\nfn main() {}", "error: arity-type at 2:9\n");
    expectMain("fn f(x: Self) {}\nfn main() {}", "error: self-outside at 1:9\n");
    expectMain("trait T { fn m(self); }\nimpl T for Int { fn m(self) {} }\nimpl T for Int { fn m(self) {} }\nfn main() {}",
        "error: dup-impl at 3:1\n");
    expectMain("trait T { fn m(self); }\nimpl T for [Int] { fn m(self) {} }\nfn main() {}", "error: bad-impl-head at 2:12\n");
    expectMain("trait T { fn m(self); }\nfn main() { 3.m(); }", "error: unsatisfied-bound at 2:15\n");
    expectMain("fn main() { 3.nothing(); }", "error: no-method at 1:15\n");
}
