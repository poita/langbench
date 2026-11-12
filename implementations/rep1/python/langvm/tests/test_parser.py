import pytest

from langvm import syntax as S
from langvm.diagnostics import CompileError
from langvm.lexer import tokenize
from langvm.parser import parse_module


def parse(text):
    return parse_module(tokenize(text), (1, len(text) + 1))


def parse_err(text):
    with pytest.raises(CompileError) as info:
        parse(text)
    return str(info.value)


def body(stmts):
    (fn,) = parse("fn f() { " + stmts + " }")
    return fn.body


def test_items():
    items = parse("use a; use b as c; pub fn f<T: X + Y>(a: T,) -> T { a } struct S<A> { x: A, }"
                  " enum E { A, B(Int, Str), } trait Tr { fn m(self); fn n(self, x: Int) -> Int { x } }"
                  " impl<T: Tr> Tr for [T] { fn m(self) {} }")
    assert [type(i).__name__ for i in items] == [
        "Use", "Use", "FnDecl", "StructDecl", "EnumDecl", "TraitDecl", "ImplDecl"
    ]
    assert items[2].pub and items[2].tparams[0].bounds[1].name == "Y"


def test_precedence_bitwise_binds_tighter_than_comparison():
    e = body("a & b == c").tail
    assert e.op == "==" and e.left.op == "&"


def test_comparison_is_non_associative():
    assert parse_err("fn f() { a < b < c }") == "error: parse at 1:16"


def test_if_statement_continues_as_expression():
    stmts = body("if c { f() } else { g() }\n(1, 2);")
    assert isinstance(stmts.stmts[0].expr, S.Call)


def test_trailing_if_without_semicolon_is_statement():
    b = body("if c { f(); } g();")
    assert isinstance(b.stmts[0], S.ExprStmt) and isinstance(b.stmts[0].expr, S.If)


def test_generic_closing_angle_brackets_split():
    (fn,) = parse("fn f(x: A<B<C>>) {}")
    t = fn.params[0].ty
    assert t.args[0].args[0].name == "C"


def test_lambda_forms():
    e = body("||  1").tail
    assert isinstance(e, S.Lambda) and e.params == []
    e = body("|a, b: Int| -> Int { a }").tail
    assert [p.name for p in e.params] == ["a", "b"] and isinstance(e.body, S.Block)
    assert parse_err("fn f() { | | 8 }").startswith("error: parse")


@pytest.mark.parametrize(
    "text",
    [
        "struct S<T: Eq> {}",
        "fn f(x: (Int)) {}",
        "pub impl A for B {}",
        "fn f() { let x = [..a, b]; }",
        "fn f() { match x { [.., a] -> 1 } }",
        "fn f() { 1 2 }",
    ],
)
def test_parse_errors(text):
    assert parse_err(text).startswith("error: parse")


def test_eof_position():
    assert parse_err("fn f( {") == "error: parse at 1:7"


def test_struct_literal_and_patterns():
    e = body("P.{ a: 1 }.a").tail
    assert isinstance(e, S.FieldAccess) and isinstance(e.obj, S.StructLit)
    arms = body("match v { P.{ a, .. } -> 1, [a, ..r] -> 2, (x, _) -> 3, -1 -> 4 }").tail.arms
    assert [type(a.pat).__name__ for a in arms] == ["PStruct", "PList", "PTuple", "PLit"]
    assert arms[0].pat.rest and arms[1].pat.rest_name == "r"
