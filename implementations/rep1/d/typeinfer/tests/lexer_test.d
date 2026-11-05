/// Unit tests for typeinfer.lexer.
module lexer_test;

import typeinfer.errors;
import typeinfer.lexer;

private Tok[] kinds(string src, Interner names = new Interner)
{
    Tok[] r;
    foreach (t; tokenize(src, names))
        r ~= t.kind;
    return r;
}

unittest // empty and whitespace-only input
{
    assert(kinds("") == [Tok.eof]);
    assert(kinds(" \t\r\n ") == [Tok.eof]);
}

unittest // keywords versus identifiers that merely start with one
{
    assert(kinds("let rec in fun if then else true false") ==
        [Tok.kwLet, Tok.kwRec, Tok.kwIn, Tok.kwFun, Tok.kwIf, Tok.kwThen,
         Tok.kwElse, Tok.kwTrue, Tok.kwFalse, Tok.eof]);
    assert(kinds("letx funny inx x1 acc_2 xY") ==
        [Tok.ident, Tok.ident, Tok.ident, Tok.ident, Tok.ident, Tok.ident, Tok.eof]);
}

unittest // longest match for symbols
{
    assert(kinds(";; -> :: <= >= && || ( ) [ ] ; , + - * / = < >") ==
        [Tok.semiSemi, Tok.arrow, Tok.colonColon, Tok.lessEq, Tok.greaterEq,
         Tok.andAnd, Tok.orOr, Tok.lparen, Tok.rparen, Tok.lbracket, Tok.rbracket,
         Tok.semi, Tok.comma, Tok.plus, Tok.minus, Tok.star, Tok.slash,
         Tok.eq, Tok.less, Tok.greater, Tok.eof]);
    assert(kinds(";;;") == [Tok.semiSemi, Tok.semi, Tok.eof]);
    assert(kinds("x->y") == [Tok.ident, Tok.arrow, Tok.ident, Tok.eof]);
    assert(kinds("a<=b") == [Tok.ident, Tok.lessEq, Tok.ident, Tok.eof]);
    assert(kinds("a<-b") == [Tok.ident, Tok.less, Tok.minus, Tok.ident, Tok.eof]);
}

unittest // integer literals of any length
{
    assert(kinds("0 42 123456789012345678901234567890") ==
        [Tok.integer, Tok.integer, Tok.integer, Tok.eof]);
}

unittest // identifiers are interned densely, case-sensitively
{
    auto names = new Interner;
    auto toks = tokenize("x y x", names);
    assert(toks[0].id == 0 && toks[1].id == 1 && toks[2].id == 0);
}

unittest // token positions
{
    auto toks = tokenize("ab  12", new Interner);
    assert(toks[0].pos == 0 && toks[1].pos == 4 && toks[2].pos == 6);
}

unittest // invalid characters raise SyntaxError
{
    import std.exception : assertThrown;

    assertThrown!SyntaxError(tokenize("@", new Interner));
    assertThrown!SyntaxError(tokenize("a : b", new Interner));
    assertThrown!SyntaxError(tokenize("a & b", new Interner));
    assertThrown!SyntaxError(tokenize("A", new Interner));
}

unittest // Interner
{
    auto n = new Interner;
    assert(n.intern("foo") == 0);
    assert(n.intern("bar") == 1);
    assert(n.intern("foo") == 0);
    assert(n.name(1) == "bar");
    assert(n.length == 2);
}
