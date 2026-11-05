module tests.lexer_test;

import std.exception : assertThrown;

import datalog.errors : ParseException;
import datalog.lexer;

private TokenKind[] kinds(string src)
{
    TokenKind[] result;
    auto lx = Lexer(src);
    for (auto t = lx.next(); t.kind != TokenKind.eof; t = lx.next())
        result ~= t.kind;
    return result;
}

unittest
{
    assert(kinds("") == []);
    assert(kinds("  % just a comment\n\t\r\n") == []);
}

unittest
{
    with (TokenKind)
        assert(kinds("p(X, _, a1, -3) :- not q(X), X <= 5.")
                == [identifier, lparen, variable, comma, anonymous, comma, identifier, comma,
                    integer, rparen, neck, not, identifier, lparen, variable, rparen, comma,
                    variable, le, integer, dot]);
}

unittest
{
    // `not` is a keyword only when it is the whole word.
    with (TokenKind)
        assert(kinds("not nothing not_x") == [not, identifier, identifier]);
}

unittest
{
    // Longest match, and a negative integer right after a comparison operator.
    with (TokenKind)
        assert(kinds("X<-1") == [variable, lt, integer]);
    with (TokenKind)
        assert(kinds("< <= > >= = != :- ?-") == [lt, le, gt, ge, eq, ne, neck, queryMark]);
}

unittest
{
    auto lx = Lexer("-17 0 1000000000 -1000000000");
    assert(lx.next().value == -17);
    assert(lx.next().value == 0);
    assert(lx.next().value == 1_000_000_000);
    assert(lx.next().value == -1_000_000_000);
}

unittest
{
    auto lx = Lexer("a % comment\n b\n\nc");
    assert(lx.next().line == 1);
    assert(lx.next().line == 2);
    assert(lx.next().line == 4);
}

unittest
{
    assertThrown!ParseException(kinds("p(a) $"));
    assertThrown!ParseException(kinds("_x"));
    assertThrown!ParseException(kinds("99999999999"));
}
