/// Unit tests for the s-expression reader and printer.
module tests.sexpr_test;

import std.exception : assertThrown;

import cardgame.sexpr;

unittest
{
    auto forms = readAll(`(card TST-001 (name "A (b); c") (cost 12) (x -3))`);
    assert(forms.length == 1);
    auto f = forms[0];
    assert(f.isForm("card"));
    assert(f.items[1].isSym("TST-001"));
    assert(f.items[2].items[1].isStr && f.items[2].items[1].text == "A (b); c");
    assert(f.items[3].items[1].isInt && f.items[3].items[1].num == 12);
    assert(f.items[4].items[1].num == -3);
}

unittest
{
    // Comments run to the end of the line; whitespace of every kind separates tokens.
    auto forms = readAll("; leading comment\n(a\t(b)\r\n\f(c)) ; trailing\n(d)");
    assert(forms.length == 2);
    assert(printSExpr(forms[0]) == "(a (b) (c))");
    assert(printSExpr(forms[1]) == "(d)");
}

unittest
{
    // Symbols versus integers.
    auto f = readAll("(1 -1 +1 1a - -x 007)")[0];
    assert(f.items[0].isInt);
    assert(f.items[1].isInt && f.items[1].num == -1);
    assert(f.items[2].isSymbol);
    assert(f.items[3].isSymbol);
    assert(f.items[4].isSymbol);
    assert(f.items[5].isSymbol);
    assert(f.items[6].isInt && f.items[6].num == 7);
}

unittest
{
    // 64-bit range limits.
    assert(readAll("(9223372036854775807)")[0].items[0].num == long.max);
    assert(readAll("(-9223372036854775808)")[0].items[0].num == long.min);
    assertThrown!SExprError(readAll("(9223372036854775808)"));
    assertThrown!SExprError(readAll("(-9223372036854775809)"));
}

unittest
{
    assertThrown!SExprError(readAll("(a (b)"));
    assertThrown!SExprError(readAll("(a))"));
    assertThrown!SExprError(readAll(`(a "unterminated)`));
    assertThrown!SExprError(readAll("(a \"new\nline\")"));
    assert(readAll("").length == 0);
    assert(readAll("; only a comment").length == 0);
}

unittest
{
    // Printing normalises whitespace only.
    auto f = readAll("(  card   X-1\n (name   \"A  B\")  ( ) )")[0];
    assert(printSExpr(f) == `(card X-1 (name "A  B") ())`);
}
