/// Tests for language semantics: evaluation order, closures, traits, generics, maps, panics.
module langvm.test_semantics;

import langvm;
import langvm.helpers;

unittest
{
    // struct literal fields evaluate in written order, then are stored in declaration order
    expectMain("struct P { a: Int, b: Int }\nfn t(n: Int) -> Int { print(showInt(n)); n }\n"
            ~ "fn main() { let p = P.{ b: t(1), a: t(2) }; print(showInt(p.a * 10 + p.b)); }", "1\n2\n21\n");
    // && and || short-circuit
    expectBody("let f = || { print(\"called\"); true };\nlet a = false && f();\nlet b = true || f();\nprint(showBool(a) ++ showBool(b));",
        "falsetrue\n");
}

unittest
{
    // closures capture by value; lists are shared
    expectBody("var base = 1;\nlet f = |d: Int| base + d;\nbase = 100;\nprint(showInt(f(5)));\n"
            ~ "let shared = [1];\nlet g = || push(shared, 2);\ng();\nprint(showInt(listLen(shared)));", "6\n2\n");
    expectBody("var fs: [fn() -> Int] = [];\nfor i in 0 .. 3 { push(fs, || i * i); }\nvar s = 0;\nfor g in fs { s = s + g(); }\nprint(showInt(s));",
        "5\n");
}

unittest
{
    // trait dispatch: default methods, generic impls, trait paths
    expectMain("trait Shape { fn area(self) -> Int; fn name(self) -> Str { \"shape\" } }\n"
            ~ "impl Shape for Int { fn area(self) -> Int { self } }\n"
            ~ "impl<T: Shape> Shape for [T] { fn area(self) -> Int { listFold(self, 0, |a, x| a + x.area()) } fn name(self) -> Str { \"list\" } }\n"
            ~ "fn main() { print([1, 2, 3].name() ++ showInt([1, 2, 3].area()) ++ 5.name() ++ showInt(Shape::area(7))); }",
        "list6shape7\n");
}

unittest
{
    // maps keep insertion order; re-assigning keeps position; delete + insert moves to the end
    expectBody("var m = #[\"a\": 1, \"b\": 2];\nm[\"a\"] = 3;\nmapDel(m, \"a\");\nm[\"a\"] = 4;\nm[\"c\"] = 5;\n"
            ~ "print(strJoin(keysOf(m), \",\") ++ showInt(mapLen(m)));\nprint(showBool(#[1: 2, 3: 4] == #[3: 4, 1: 2]));",
        "b,a,c3\ntrue\n");
}

unittest
{
    // integer semantics
    expectBody("print(showInt(intMax() + 1));\nprint(showInt(-7 / 2) ++ \" \" ++ showInt(-7 % 2));\nprint(showInt(intMin() / -1));\n"
            ~ "print(showInt(-16 >> 2) ++ \" \" ++ showInt(1 << 62));",
        "-9223372036854775808\n-3 -1\n-9223372036854775808\n-4 4611686018427387904\n");
}

unittest
{
    // panics: output is kept, the panic line continues the last emit
    expectBody("emit(\"a\");\nlet xs = [1];\nprint(showInt(xs[3]));", "apanic: index out of bounds\n");
    expectBody("print(showInt(1 / 0));", "panic: divide by zero\n");
    expectBody("panic(\"custom\");", "panic: custom\n");
    expectMain("fn down(n: Int) -> Int { if n == 0 { return 0; } down(n - 1) + 1 }\nfn main() { print(showInt(down(30000))); }",
        "panic: call stack overflow\n");
    expectMain("fn down(n: Int) -> Int { if n == 0 { return 0; } down(n - 1) + 1 }\nfn main() { print(showInt(down(15000))); }",
        "15000\n");
}

unittest
{
    // the library API: compile then execute
    auto c = compile("@module main\nfn main() { print(\"hi\"); }\n");
    auto r = execute(c);
    assert(r.outcome == Outcome.finished && r.stdout == "hi\n");
    auto bad = runSource("@module main\nfn main() { 1 + }\n");
    assert(bad.outcome == Outcome.compileError);
    auto p = runSource("@module main\nfn main() { panic(\"x\"); }\n");
    assert(p.outcome == Outcome.panicked);
}
