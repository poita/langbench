/// Tests for the parser.
module langvm.test_parser;

import langvm;
import langvm.ast;
import langvm.lexer;
import langvm.parser;
import std.exception : collectException;

private ModuleAst parse(string s)
{
    import std.utf : toUTF32;

    return Parser.parseModule("m", Lexer.lex([toUTF32(s)]));
}

private string parseError(string s)
{
    auto e = collectException!CompileError(parse(s));
    return e is null ? "ok" : e.msg;
}

unittest
{
    auto m = parse("use a; pub fn f<T: Eq + Ord>(x: T, y: [T],) -> Int { 1 } struct S { a: Int, } enum E { A, B(Int, Str) } "
            ~ "trait Tr { fn m(self) -> Int; fn d(self) {} } impl Tr for Int { fn m(self) -> Int { 1 } }");
    assert(m.items.length == 6);
    assert(cast(UseItem) m.items[0]);
    auto f = cast(FnItem) m.items[1];
    assert(f.pub && f.gen.length == 1 && f.gen[0].bounds.length == 2 && f.params.length == 2);
}

unittest
{
    // comparison is non-associative; bitwise operators bind tighter than comparison
    assert(parseError("fn f() { 1 < 2 < 3; }") == "error: parse at 1:16");
    assert(parseError("fn f() { a & b == c; }") == "ok");
    auto m = parse("fn f() { a & b == c; }");
    auto body_ = (cast(FnItem) m.items[0]).body;
    auto e = (cast(ExprStmt) body_.stmts[0]).e;
    auto top = cast(Binary) e;
    assert(top !is null && top.op == Tk.eqEq);
}

unittest
{
    assert(parseError("fn f() { if c { 1 } else { 2 } (1, 2); }") == "ok"); // continues as a call
    assert(parseError("fn f() { 1 2 }") == "error: parse at 1:12");
    assert(parseError("fn f(") == "error: parse at 1:6");
    assert(parseError("struct S<T: Eq> { }") == "error: parse at 1:11");
    assert(parseError("fn f() { let x: (Int) = 1; }") == "error: parse at 1:21");
    assert(parseError("fn f() { let x: A<B<C>> = 1; }") == "ok");
    assert(parseError("fn f() { | | 8; }") == "error: parse at 1:12");
    assert(parseError("pub impl A for B {}") == "error: parse at 1:5");
}

unittest
{
    assert(parseError("fn f() { match x { A -> 1, B -> { 2 } C -> 3 } }") == "ok");
    assert(parseError("fn f() { match x { A -> 1 B -> 2 } }") == "error: parse at 1:27");
    assert(parseError("fn f() { match x { [a, ..r, b] -> 1 } }") == "error: parse at 1:27");
    assert(parseError("fn f() { match x { P.{ a, .. } -> 1, [..] -> 2, (a, b,) -> 3 } }") == "ok");
}
