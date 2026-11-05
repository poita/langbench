/// Tests for pattern typing, exhaustiveness and reachability (section 12 of the specification).
module langvm.test_patterns;

import langvm;
import langvm.helpers;

private enum decls = "enum Tri { A, B, C(Int) }\nfn f() -> Bool { true }\n";

private void eq(string got, string want, string file = __FILE__, size_t line = __LINE__)
{
    import core.exception : AssertError;

    if (got != want)
        throw new AssertError("expected: " ~ want ~ "got: " ~ got, file, line);
}

/// Runs `fn main() { let t = A; <match expression statement> }` and returns the result.
private string matchOn(string scrutinee, string arms, string prelude = "")
{
    return runMain(decls ~ prelude ~ "fn main() {\n let v = " ~ scrutinee ~ ";\n match v {\n" ~ arms ~ "\n }\n}");
}

unittest
{
    // worked cases of section 12.5
    eq(matchOn("A", "A -> print(\"a\"), B -> print(\"b\"), C(n) -> print(showInt(n))"), "a\n");
    eq(matchOn("A", "A -> print(\"a\"), C(_) -> print(\"c\")"), "error: non-exhaustive at 5:2\n");
    eq(matchOn("A", "A -> print(\"a\"), B -> print(\"b\"), C(0) -> print(\"c0\"), C(_) -> print(\"c\")"), "a\n");
    eq(matchOn("A", "_ -> print(\"w\"),\n A -> print(\"a\")"), "error: unreachable at 7:2\n");
    eq(matchOn("A", "A when f() -> print(\"g\"), A -> print(\"a\"), B -> print(\"b\"), C(_) -> print(\"c\")"), "g\n");
    eq(matchOn("A", "A when f() -> print(\"g\")"), "error: non-exhaustive at 5:2\n");
}

unittest
{
    // lists: the length constructors 0..Lmax+1
    eq(matchOn("[1, 2, 3]", "[] -> print(\"0\"), [a] -> print(\"1\"), [a, b, ..] -> print(showInt(a + b))"), "3\n");
    eq(matchOn("[1]", "[] -> print(\"0\"), [a] -> print(\"1\")"), "error: non-exhaustive at 5:2\n");
    eq(matchOn("[1]", "[] -> print(\"0\"), [_, ..] -> print(\"1\"), [..] -> print(\"2\")"), "error: unreachable at 6:42\n");
    eq(matchOn("[1, 2]", "[a, ..rest] -> print(showInt(listLen(rest))), [] -> print(\"e\")"), "1\n");
}

unittest
{
    // literals, tuples, bools, structs
    eq(matchOn("1", "0 -> print(\"z\"), 1 -> print(\"o\")"), "error: non-exhaustive at 5:2\n");
    eq(matchOn("true", "true -> print(\"t\"), false -> print(\"f\")"), "t\n");
    eq(matchOn("(false, false)", "(true, _) -> print(\"1\"), (_, true) -> print(\"2\"), (false, false) -> print(\"3\")"), "3\n");
    eq(matchOn("(true, false)", "(true, _) -> print(\"1\"), (_, true) -> print(\"2\")"), "error: non-exhaustive at 5:2\n");
    eq(matchOn("\"a\"", "\"a\" -> print(\"x\"), _ -> print(\"y\")"), "x\n");
    eq(matchOn("1.5", "1.5 -> print(\"x\"), _ -> print(\"y\")"), "error: bad-pattern at 6:1\n");
    eq(matchOn("P.{ a: 1, b: 2 }", "P.{ a: 1, b: _ } -> print(\"x\")", "struct P { a: Int, b: Int }\n"), "error: non-exhaustive at 6:2\n");
    eq(matchOn("P.{ a: 1, b: 2 }", "P.{ a: 1, .. } -> print(\"x\"), P.{ b, .. } -> print(showInt(b))", "struct P { a: Int, b: Int }\n"), "x\n");
}

unittest
{
    // an empty enum has no values: no arm is useful, and a match without arms is non-exhaustive
    assert(runMain("enum Never {}\nfn g(v: Never) -> Int { match v { _ -> 0 } }\nfn main() {}") == "error: unreachable at 2:35\n");
    expectBody("let r = match 1 { };", "error: non-exhaustive at 2:9\n");
}

unittest
{
    // irrefutable patterns in let and for
    expectBody("let (a, (b, c)) = (1, (2, 3));\nprint(showInt(a + b + c));\nfor (x, _) in [(5, 6)] { print(showInt(x)); }", "6\n5\n");
    expectBody("let [a, b] = [1, 2];", "error: refutable-pattern at 2:5\n");
    expectBody("let Some(x) = Some(1);", "error: refutable-pattern at 2:5\n");
    expectBody("for 1 in [1, 2] { }", "error: refutable-pattern at 2:5\n");
    expectMain("enum One { Only(Int) }\nfn main() { let Only(x) = Only(7); print(showInt(x)); }", "7\n");
}
