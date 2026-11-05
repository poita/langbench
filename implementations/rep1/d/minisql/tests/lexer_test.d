module tests.lexer_test;

import minisql.lexer;

private Tok[] kinds(string s)
{
    Tok[] r;
    foreach (t; tokenize(s))
        r ~= t.kind;
    return r;
}

unittest // keywords are case-insensitive, identifiers are lower-cased
{
    auto t = tokenize("SeLeCt FooBar");
    assert(t.length == 2);
    assert(t[0].kind == Tok.kSelect);
    assert(t[1].kind == Tok.ident && t[1].text == "foobar");
}

unittest // aggregate names are ordinary identifiers
{
    assert(kinds("count (*)") == [Tok.ident, Tok.lparen, Tok.star, Tok.rparen]);
}

unittest // operators: longest match
{
    assert(kinds("<= <> != == = < > >=") ==
            [Tok.le, Tok.ne, Tok.ne, Tok.eq, Tok.eq, Tok.lt, Tok.gt, Tok.ge]);
}

unittest // comments and whitespace
{
    assert(kinds("1 -- comment ; here\n2") == [Tok.integer, Tok.integer]);
    assert(kinds("--5") == []);
    assert(kinds("1\f\v\t\r\n2") == [Tok.integer, Tok.integer]);
}

unittest // string literals
{
    auto t = tokenize("'it''s' '' 'a;b'");
    assert(t.length == 3);
    assert(t[0].text == "it's");
    assert(t[1].text == "");
    assert(t[2].text == "a;b");
    assert(tokenize("'\\n'")[0].text == "\\n");
}

unittest // unterminated string ends the scan
{
    assert(kinds("select 'abc; select 1;") == [Tok.kSelect, Tok.unterminated]);
}

unittest // integers and invalid characters
{
    auto t = tokenize("007 1.5 \" @ é");
    assert(t[0].kind == Tok.integer && t[0].value == 7);
    assert(t[1].kind == Tok.integer && t[2].kind == Tok.dot && t[3].kind == Tok.integer);
    foreach (x; t[4 .. $])
        assert(x.kind == Tok.invalid);
}

unittest // statements split on semicolons only
{
    auto s = splitStatements(tokenize(";; select 1; ; select 2"));
    assert(s.length == 2);
    assert(s[0].length == 2 && s[1].length == 2);
    assert(splitStatements(tokenize("-- nothing\n ;")).length == 0);
}
