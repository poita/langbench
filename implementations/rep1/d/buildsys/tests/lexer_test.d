/// Unit tests for kiln.lexer.
module lexer_test;

import std.exception : collectException;

import kiln.errors;
import kiln.lexer;

private string lexError(string text)
{
    auto e = collectException!KilnError(lexSource("f.kiln", text));
    return e is null ? "" : e.render;
}

unittest // comments are stripped outside literals only
{
    auto ls = lexSource("f", "let a = \"x # y\" # trailing\nlet b = 'p#q'\n");
    assert(ls.length == 2);
    assert(ls[0].text == `let a = "x # y"`);
    assert(ls[1].text == `let b = 'p#q'`);
}

unittest // brackets join physical lines; the line number is the first line
{
    auto ls = lexSource("f", "let a = [\n  1,\n  2\n]\nlet b = 2\n");
    assert(ls.length == 2);
    assert(ls[0].line == 1);
    assert(ls[1].line == 5);
    assert(ls[0].text == "let a = [   1,   2 ]");
}

unittest // errors are attributed to the first physical line of the logical line
{
    assert(lexError("let b = f(\n  \"unterminated\n)\n") == "E_PARSE f.kiln:1");
    assert(lexError("x = 1\n)\n") == "E_PARSE f.kiln:2");
    assert(lexError("a\nlet x = (1\n") == "E_PARSE f.kiln:2");
    assert(lexError("a | b\n") == "E_PARSE f.kiln:1");
    assert(lexError("a & b\n") == "E_PARSE f.kiln:1");
}

unittest // the earliest lexical error wins, even over earlier grammar errors
{
    assert(lexError("let = 1\nlet x = \"abc\n") == "E_PARSE f.kiln:2");
}

unittest // nested literals inside interpolation do not close the outer literal
{
    auto ls = lexSource("f", "cmd write(\"{join(xs, \", \")}\\n\")\n");
    assert(ls.length == 1);
    assert(ls[0].tokens[$ - 2].kind == TokKind.str);
}

unittest // operators are matched longest first
{
    Token[] t;
    assert(tokenize("a |> b || c && d == e != f <= g >= h ++ i < j", t));
    string[] syms;
    foreach (x; t)
        if (x.kind == TokKind.sym)
            syms ~= x.text;
    assert(syms == ["|>", "||", "&&", "==", "!=", "<=", ">=", "++", "<"]);
}

unittest // integers keep their value; leading zeros are decimal
{
    Token[] t;
    assert(tokenize("007 12", t));
    assert(t[0].value == 7 && t[1].value == 12);
}

unittest // reserved words
{
    assert(isReserved("cost"));
    assert(isReserved("true"));
    assert(!isReserved("weight"));
}

unittest // literal scanner
{
    assert(scanLiteral(`ab"cd`, 0, '"') == 3);
    assert(scanLiteral(`a''b' tail`, 0, '\'') == 5);
    assert(scanLiteral(`{x}"`, 0, '"') == 4);
    assert(scanLiteral(`{"}"}"z`, 0, '"') == 6);
    assert(scanLiteral(`abc`, 0, '"') == -1);
    assert(scanLiteral(`{x"`, 0, '"') == -1);
}
