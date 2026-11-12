import pytest

from typeinfer import ParseError, parse_expr, parse_program
from typeinfer.lexer import tokenize
from typeinfer.syntax import App, BinOp, Cons, Decl, Fun, If, IntLit, Let, LetRec, ListLit, Tuple, UnitLit, Var


def kinds(src):
    return [t.kind for t in tokenize(src)][:-1]


def test_longest_match_and_keywords():
    assert kinds("a->b;;c::d<=e>=f&&g||h") == [
        "ident", "->", "ident", ";;", "ident", "::", "ident", "<=", "ident",
        ">=", "ident", "&&", "ident", "||", "ident",
    ]
    assert kinds("letx inx funny let in") == ["ident", "ident", "ident", "let", "in"]
    assert kinds("x_1 aB9 123456789012345678901234567890") == ["ident", "ident", "int"]


def test_bad_character():
    with pytest.raises(ParseError):
        tokenize("let x = #;;")


def test_precedence():
    e = parse_expr("f x + g y * 2")
    assert e == BinOp("+", App(Var("f"), [Var("x")]), BinOp("*", App(Var("g"), [Var("y")]), IntLit("2")))
    e = parse_expr("1 :: f x :: l")
    assert e == Cons(IntLit("1"), Cons(App(Var("f"), [Var("x")]), Var("l")))
    assert parse_expr("a < b && c") == BinOp("&&", BinOp("<", Var("a"), Var("b")), Var("c"))
    assert parse_expr("a - b - c") == BinOp("-", BinOp("-", Var("a"), Var("b")), Var("c"))


def test_bodies_stop_at_comma_and_semicolon():
    assert parse_expr("(fun x -> x, 1)") == Tuple([Fun(["x"], Var("x")), IntLit("1")])
    assert parse_expr("[fun x -> x; 1]") == ListLit([Fun(["x"], Var("x")), IntLit("1")])
    assert parse_expr("(let y = 1 in y, 2)") == Tuple([Let("y", IntLit("1"), Var("y")), IntLit("2")])


def test_if_else_extends_right():
    e = parse_expr("if a then b else c + 1")
    assert e == If(Var("a"), Var("b"), BinOp("+", Var("c"), IntLit("1")))


def test_sugar():
    assert parse_expr("let f x y = x in f") == Let("f", Fun(["x", "y"], Var("x")), Var("f"))
    assert parse_expr("let rec f x = f x in f") == LetRec(
        "f", Fun(["x"], App(Var("f"), [Var("x")])), Var("f")
    )


def test_declarations():
    decls = parse_program("let x = 1;; let rec f n = f n;; ();;")
    assert [d.name for d in decls] == ["x", "f", None]
    assert [d.recursive for d in decls] == [False, True, False]
    assert decls[2] == Decl(None, UnitLit())
    assert parse_program("  \n\t ") == []


def test_tuple_of_three_is_flat():
    e = parse_expr("(1, 2, 3)")
    assert isinstance(e, Tuple) and len(e.items) == 3


@pytest.mark.parametrize("src", ["let rec x = 1;;", "fun -> 1;;", "(1, ;;", "1"])
def test_syntax_errors(src):
    with pytest.raises(ParseError):
        parse_program(src)
