/// Tests for the lexer.
module langvm.test_lexer;

import langvm;
import langvm.lexer;
import std.exception : collectException;

private Token[] lex(string s)
{
    import std.utf : toUTF32;

    return Lexer.lex([toUTF32(s)]);
}

private string lexError(string s)
{
    auto e = collectException!CompileError(lex(s));
    return e is null ? "ok" : e.msg;
}

unittest
{
    auto t = lex("let x = 0x1F + 1_000;");
    assert(t[0].kind == Tk.kwLet);
    assert(t[3].kind == Tk.intLit && t[3].ival == 31);
    assert(t[5].ival == 1000);
    assert(t[$ - 1].kind == Tk.eof);
}

unittest
{
    auto t = lex("1_.5 1e1_0 1e 1. 0..3");
    assert(t[0].kind == Tk.floatLit && t[0].fval == 1.5);
    assert(t[1].kind == Tk.floatLit && t[1].fval == 1e10);
    assert(t[2].kind == Tk.intLit && t[3].kind == Tk.ident);
    assert(t[4].kind == Tk.intLit && t[5].kind == Tk.dot);
    assert(t[6].kind == Tk.intLit && t[7].kind == Tk.dotDot && t[8].kind == Tk.intLit);
}

unittest
{
    assert(lexError("9223372036854775808") == "error: int-range at 1:1");
    assert(lexError("9223372036854775807") == "ok");
    assert(lexError("0x") == "error: bad-token at 1:1");
    assert(lexError("0x_1") == "error: bad-token at 1:1");
    assert(lexError("#") == "error: bad-token at 1:1");
    assert(lexError("é") == "error: bad-token at 1:1");
}

unittest
{
    assert(lexError(`"abc\q`) == "error: bad-escape at 1:5");
    assert(lexError(`'ab'`) == "error: unterminated at 1:1");
    assert(lexError(`'\q'`) == "error: bad-escape at 1:2");
    assert(lexError(`"\u{110000}"`) == "error: bad-escape at 1:2");
    assert(lexError(`"\u{1f600}"`) == "ok");
    assert(lexError("/* a /* b */ c */ ok") == "ok");
    assert(lexError("x /* never closed") == "error: unterminated at 1:3");
}

unittest
{
    auto t = lex(`"a\n\u{41}"`);
    assert(t[0].kind == Tk.strLit && t[0].sval == "a\nA"d);
    t = lex("'\\''");
    assert(t[0].kind == Tk.charLit && t[0].ival == '\'');
    t = lex("#[ :: .. -> == != <= >= && || << >> ++ _ __");
    assert(t[0].kind == Tk.hashBracket && t[1].kind == Tk.colonColon && t[12].kind == Tk.plusPlus);
    assert(t[13].kind == Tk.underscore && t[14].kind == Tk.ident);
}
