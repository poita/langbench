module datalog_tests.lexer;

import std.algorithm : equal, map;
import std.array : array;
import datalog.errors : ParseException;
import datalog.lexer;
import std.exception : assertThrown;

private Token[] lexAll(string s)
{
    Token[] r;
    auto lx = Lexer(s);
    for (auto t = lx.next(); t.kind != TokenKind.eof; t = lx.next())
        r ~= t;
    return r;
}

private TokenKind[] kinds(string s) { return lexAll(s).map!(t => t.kind).array; }

unittest // basic clause
{
    with (TokenKind)
        assert(kinds("p(X, a1_b, -3, _).") ==
            [identifier, lparen, variable, comma, identifier, comma, integer, comma, anonymous, rparen, dot]);
}

unittest // longest match and negative numbers
{
    with (TokenKind)
    {
        assert(kinds("X<=Y") == [variable, le, variable]);
        assert(kinds("X<-1") == [variable, lt, integer]);
        assert(kinds("X>=0 X>0 X!=Y X=Y") ==
            [variable, ge, integer, variable, gt, integer, variable, ne, variable, variable, eq, variable]);
        assert(kinds("p:-q. ?-p(X).")[1] == implies);
        assert(kinds("?- p")[0] == queryMark);
    }
}

unittest // keyword vs identifiers
{
    with (TokenKind)
        assert(kinds("not nothing not_x") == [kwNot, identifier, identifier]);
}

unittest // comments and whitespace
{
    assert(lexAll("% only a comment\n \t\r\n").length == 0);
    auto ts = lexAll("a % c\n b");
    assert(ts.length == 2 && ts[0].text == "a" && ts[1].text == "b");
}

unittest // bad input
{
    assertThrown!ParseException(lexAll("p(a) $"));
    assertThrown!ParseException(lexAll("a ! b"));
}
