module lexer_test;

import datalog.lexer;

private TokenKind[] kinds(string s)
{
    TokenKind[] r;
    auto lx = Lexer(s);
    for (auto t = lx.next(); t.kind != TokenKind.eof; t = lx.next())
        r ~= t.kind;
    return r;
}

unittest // punctuation uses longest match
{
    assert(kinds("<= < >= > = != :- ?-") == [
        TokenKind.le, TokenKind.lt, TokenKind.ge, TokenKind.gt, TokenKind.eq,
        TokenKind.ne, TokenKind.ruleArrow, TokenKind.queryArrow]);
}

unittest // negative integers after comparison operators
{
    auto lx = Lexer("X<-1");
    assert(lx.next().kind == TokenKind.variable);
    assert(lx.next().kind == TokenKind.lt);
    const t = lx.next();
    assert(t.kind == TokenKind.integer && t.value == -1);
}

unittest // keyword vs identifier, anonymous variable
{
    assert(kinds("not nothing not_x _ X_1 a0_") == [
        TokenKind.kwNot, TokenKind.identifier, TokenKind.identifier,
        TokenKind.anonymous, TokenKind.variable, TokenKind.identifier]);
}

unittest // comments and line numbers
{
    auto lx = Lexer("% hi\n  a % x\n\nb");
    assert(lx.next().line == 2);
    const b = lx.next();
    assert(b.line == 4 && b.text == "b");
    assert(lx.next().kind == TokenKind.eof);
}

unittest // bad characters throw
{
    import std.exception : assertThrown;
    auto lx = Lexer("a @");
    lx.next();
    assertThrown!ParseException(lx.next());
}
