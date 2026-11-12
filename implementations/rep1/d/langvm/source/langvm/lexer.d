/// The lexer (SPEC.md section 3).
module langvm.lexer;

import langvm.diag;
import langvm.source : SourceModule;

/// Token kinds.
enum T : ubyte
{
    eof,
    ident,
    int_,
    float_,
    str,
    char_,
    // keywords
    kwAs, kwBreak, kwContinue, kwElse, kwEnum, kwFalse, kwFn, kwFor, kwIf, kwImpl,
    kwIn, kwLet, kwMatch, kwPub, kwReturn, kwSelf, kwStruct, kwTrait, kwTrue, kwUse,
    kwVar, kwWhen, kwWhile,
    // multi-character punctuation
    hashBracket, colonColon, dotDot, arrow, eqEq, ne, le, ge, andAnd, orOr, shl, shr,
    plusPlus,
    // single-character punctuation
    lparen, rparen, lbracket, rbracket, lbrace, rbrace, comma, semi, colon, dot, pipe,
    plus, minus, star, slash, percent, bang, tilde, amp, caret, lt, gt, eq, underscore,
}

/// A lexical token with its position and literal payload.
struct Token
{
    T kind;
    Pos pos;
    /// Value of an integer literal, or the scalar of a character literal.
    long ival;
    /// Value of a float literal.
    double fval;
    /// Text of an identifier.
    string id;
    /// Value of a string literal.
    dstring sval;
}

private immutable T[string] keywordTable;

shared static this()
{
    keywordTable = [
        "as": T.kwAs, "break": T.kwBreak, "continue": T.kwContinue, "else": T.kwElse,
        "enum": T.kwEnum, "false": T.kwFalse, "fn": T.kwFn, "for": T.kwFor, "if": T.kwIf,
        "impl": T.kwImpl, "in": T.kwIn, "let": T.kwLet, "match": T.kwMatch, "pub": T.kwPub,
        "return": T.kwReturn, "self": T.kwSelf, "struct": T.kwStruct, "trait": T.kwTrait,
        "true": T.kwTrue, "use": T.kwUse, "var": T.kwVar, "when": T.kwWhen, "while": T.kwWhile,
    ];
}

/// Is `s` a reserved word?
bool isKeyword(string s) @trusted
{
    return (s in keywordTable) !is null;
}

/// Is `s` a valid identifier (ASCII, not a keyword, not a lone `_`)?
bool isIdentifier(string s) @safe
{
    if (s.length == 0 || s.length > 200 || s == "_")
        return false;
    if (!isIdStart(s[0]))
        return false;
    foreach (c; s)
        if (!isIdCont(c))
            return false;
    return !isKeyword(s);
}

private bool isIdStart(int c) @safe pure nothrow @nogc
{
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_';
}

private bool isIdCont(int c) @safe pure nothrow @nogc
{
    return isIdStart(c) || isDigit(c);
}

private bool isDigit(int c) @safe pure nothrow @nogc
{
    return c >= '0' && c <= '9';
}

private int hexVal(int c) @safe pure nothrow @nogc
{
    if (c >= '0' && c <= '9')
        return c - '0';
    if (c >= 'a' && c <= 'f')
        return c - 'a' + 10;
    if (c >= 'A' && c <= 'F')
        return c - 'A' + 10;
    return -1;
}

/// The position just past the last token of `m`: used for "unexpected end of input".
Pos endPos(const SourceModule m) @safe pure nothrow @nogc
{
    if (m.lines.length == 0)
        return Pos(1, 1);
    return Pos(cast(int) m.lines.length, cast(int) m.lines[$ - 1].length + 1);
}

/// Lex a whole module body. The returned list always ends with an `eof` token.
Token[] lex(const SourceModule m) @trusted
{
    dchar[] text;
    foreach (i, ln; m.lines)
    {
        if (i)
            text ~= '\n';
        text ~= ln;
    }
    auto lx = Lexer(text);
    lx.run();
    lx.toks ~= Token(T.eof, endPos(m));
    return lx.toks;
}

private struct Lexer
{
    const(dchar)[] s;
    size_t i;
    int line = 1, col = 1;
    Token[] toks;

    this(const(dchar)[] s)
    {
        this.s = s;
        toks.reserve(s.length / 3 + 8);
    }

    Pos pos() const
    {
        return Pos(line, col);
    }

    /// The character `k` positions ahead, or -1 past the end.
    int at(size_t k = 0) const
    {
        return i + k < s.length ? cast(int) s[i + k] : -1;
    }

    void adv()
    {
        if (s[i] == '\n')
        {
            line++;
            col = 1;
        }
        else
            col++;
        i++;
    }

    void emit(T k, Pos p)
    {
        Token t;
        t.kind = k;
        t.pos = p;
        toks ~= t;
    }

    void run()
    {
        while (true)
        {
            skipTrivia();
            const c = at();
            if (c < 0)
                return;
            const p = pos();
            if (isIdStart(c))
                lexWord(p);
            else if (isDigit(c))
                lexNumber(p);
            else if (c == '"')
                lexString(p);
            else if (c == '\'')
                lexChar(p);
            else
                lexPunct(p);
        }
    }

    void skipTrivia()
    {
        while (true)
        {
            const c = at();
            if (c == ' ' || c == '\t' || c == '\n' || c == '\r')
                adv();
            else if (c == '/' && at(1) == '/')
            {
                while (at() >= 0 && at() != '\n')
                    adv();
            }
            else if (c == '/' && at(1) == '*')
            {
                const p = pos();
                adv();
                adv();
                int depth = 1;
                while (depth > 0)
                {
                    if (at() < 0)
                        throw err(Kind.unterminated, p);
                    if (at() == '/' && at(1) == '*')
                    {
                        adv();
                        adv();
                        depth++;
                    }
                    else if (at() == '*' && at(1) == '/')
                    {
                        adv();
                        adv();
                        depth--;
                    }
                    else
                        adv();
                }
            }
            else
                return;
        }
    }

    void lexWord(Pos p)
    {
        const start = i;
        while (isIdCont(at()))
            adv();
        const word = s[start .. i];
        if (word.length > 200)
            throw err(Kind.badToken, p);
        if (word.length == 1 && word[0] == '_')
        {
            emit(T.underscore, p);
            return;
        }
        char[] w = new char[word.length];
        foreach (k, c; word)
            w[k] = cast(char) c;
        string id = cast(string) w;
        if (auto kw = id in keywordTable)
            emit(*kw, p);
        else
        {
            Token t;
            t.kind = T.ident;
            t.pos = p;
            t.id = id;
            toks ~= t;
        }
    }

    /// Scan `digit { digit | "_" }` into `buf` (underscores dropped); the first
    /// character must be a digit.
    void digitRun(ref char[] buf)
    {
        while (isDigit(at()) || at() == '_')
        {
            if (at() != '_')
                buf ~= cast(char) at();
            adv();
        }
    }

    void lexNumber(Pos p)
    {
        if (at() == '0' && (at(1) == 'x' || at(1) == 'b'))
        {
            const hex = at(1) == 'x';
            adv();
            adv();
            const base = hex ? 16 : 2;
            const first = hexVal(at());
            if (first < 0 || first >= base)
                throw err(Kind.badToken, p);
            ulong v = 0;
            bool overflow = false;
            while (true)
            {
                const c = at();
                if (c == '_')
                {
                    adv();
                    continue;
                }
                const d = hexVal(c);
                if (d < 0 || d >= base)
                    break;
                if (v > (ulong.max - d) / base)
                    overflow = true;
                v = v * base + d;
                adv();
            }
            intToken(p, v, overflow);
            return;
        }
        char[] buf;
        digitRun(buf);
        bool isFloat = false;
        if (at() == '.' && isDigit(at(1)))
        {
            isFloat = true;
            buf ~= '.';
            adv();
            digitRun(buf);
        }
        const e = at();
        if ((e == 'e' || e == 'E') && (isDigit(at(1)) || ((at(1) == '+' || at(1) == '-') && isDigit(at(2)))))
        {
            isFloat = true;
            buf ~= 'e';
            adv();
            if (at() == '+' || at() == '-')
            {
                buf ~= cast(char) at();
                adv();
            }
            digitRun(buf);
        }
        if (isFloat)
        {
            import core.stdc.stdlib : strtod;

            buf ~= '\0';
            Token t;
            t.kind = T.float_;
            t.pos = p;
            t.fval = strtod(buf.ptr, null);
            toks ~= t;
            return;
        }
        ulong v = 0;
        bool overflow = false;
        foreach (c; buf)
        {
            const d = c - '0';
            if (v > (ulong.max - d) / 10)
                overflow = true;
            v = v * 10 + d;
        }
        intToken(p, v, overflow);
    }

    void intToken(Pos p, ulong v, bool overflow)
    {
        if (overflow || v > cast(ulong) long.max)
            throw err(Kind.intRange, p);
        Token t;
        t.kind = T.int_;
        t.pos = p;
        t.ival = cast(long) v;
        toks ~= t;
    }

    /// Read an escape; `i` is at the backslash. Returns the scalar value.
    int readEscape()
    {
        const bs = pos();
        adv();
        const c = at();
        switch (c)
        {
        case 'n':
            adv();
            return '\n';
        case 't':
            adv();
            return '\t';
        case 'r':
            adv();
            return '\r';
        case '0':
            adv();
            return 0;
        case '\\':
            adv();
            return '\\';
        case '\'':
            adv();
            return '\'';
        case '"':
            adv();
            return '"';
        case 'u':
            adv();
            if (at() != '{')
                throw err(Kind.badEscape, bs);
            adv();
            int digits = 0;
            long v = 0;
            while (hexVal(at()) >= 0)
            {
                v = v * 16 + hexVal(at());
                digits++;
                if (digits > 6)
                    throw err(Kind.badEscape, bs);
                adv();
            }
            if (digits == 0 || at() != '}')
                throw err(Kind.badEscape, bs);
            adv();
            if (v > 0x10FFFF || (v >= 0xD800 && v <= 0xDFFF))
                throw err(Kind.badEscape, bs);
            return cast(int) v;
        default:
            throw err(Kind.badEscape, bs);
        }
    }

    void lexString(Pos p)
    {
        adv();
        dchar[] val;
        while (true)
        {
            const c = at();
            if (c < 0 || c == '\n' || c == '\r')
                throw err(Kind.unterminated, p);
            if (c == '"')
            {
                adv();
                break;
            }
            if (c == '\\')
                val ~= cast(dchar) readEscape();
            else
            {
                val ~= cast(dchar) c;
                adv();
            }
        }
        Token t;
        t.kind = T.str;
        t.pos = p;
        t.sval = cast(dstring) val;
        toks ~= t;
    }

    void lexChar(Pos p)
    {
        adv();
        int v;
        const c = at();
        if (c == '\\')
            v = readEscape();
        else if (c < 0 || c == '\'' || c == '\n' || c == '\r')
            throw err(Kind.unterminated, p);
        else
        {
            v = c;
            adv();
        }
        if (at() != '\'')
            throw err(Kind.unterminated, p);
        adv();
        Token t;
        t.kind = T.char_;
        t.pos = p;
        t.ival = v;
        toks ~= t;
    }

    void lexPunct(Pos p)
    {
        const c = at();
        const d = at(1);
        T two = T.eof;
        switch (c)
        {
        case '#':
            if (d == '[')
                two = T.hashBracket;
            else
                throw err(Kind.badToken, p);
            break;
        case ':':
            if (d == ':')
                two = T.colonColon;
            break;
        case '.':
            if (d == '.')
                two = T.dotDot;
            break;
        case '-':
            if (d == '>')
                two = T.arrow;
            break;
        case '=':
            if (d == '=')
                two = T.eqEq;
            break;
        case '!':
            if (d == '=')
                two = T.ne;
            break;
        case '<':
            if (d == '=')
                two = T.le;
            else if (d == '<')
                two = T.shl;
            break;
        case '>':
            if (d == '=')
                two = T.ge;
            else if (d == '>')
                two = T.shr;
            break;
        case '&':
            if (d == '&')
                two = T.andAnd;
            break;
        case '|':
            if (d == '|')
                two = T.orOr;
            break;
        case '+':
            if (d == '+')
                two = T.plusPlus;
            break;
        default:
            break;
        }
        if (two != T.eof)
        {
            adv();
            adv();
            emit(two, p);
            return;
        }
        T one;
        switch (c)
        {
        case '(': one = T.lparen; break;
        case ')': one = T.rparen; break;
        case '[': one = T.lbracket; break;
        case ']': one = T.rbracket; break;
        case '{': one = T.lbrace; break;
        case '}': one = T.rbrace; break;
        case ',': one = T.comma; break;
        case ';': one = T.semi; break;
        case ':': one = T.colon; break;
        case '.': one = T.dot; break;
        case '|': one = T.pipe; break;
        case '+': one = T.plus; break;
        case '-': one = T.minus; break;
        case '*': one = T.star; break;
        case '/': one = T.slash; break;
        case '%': one = T.percent; break;
        case '!': one = T.bang; break;
        case '~': one = T.tilde; break;
        case '&': one = T.amp; break;
        case '^': one = T.caret; break;
        case '<': one = T.lt; break;
        case '>': one = T.gt; break;
        case '=': one = T.eq; break;
        default:
            throw err(Kind.badToken, p);
        }
        adv();
        emit(one, p);
    }
}

version (unittest)
{
    private Token[] lexString_(string src)
    {
        import langvm.source : decodeUtf8, splitLines;

        return lex(SourceModule("t", splitLines(decodeUtf8(src))));
    }

    private Kind lexError(string src)
    {
        try
        {
            lexString_(src);
        }
        catch (CompileError e)
            return e.kind;
        assert(false, "expected a lex error");
    }
}

unittest
{
    auto t = lexString_("let x = 1_000 + 0xFF;");
    assert(t[0].kind == T.kwLet);
    assert(t[1].kind == T.ident && t[1].id == "x");
    assert(t[3].kind == T.int_ && t[3].ival == 1000);
    assert(t[5].kind == T.int_ && t[5].ival == 255);
}

unittest
{
    auto t = lexString_("1.5 1e1_0 1_.5 0..3 1e 1e_5");
    assert(t[0].kind == T.float_ && t[0].fval == 1.5);
    assert(t[1].kind == T.float_ && t[1].fval == 1e10);
    assert(t[2].kind == T.float_ && t[2].fval == 1.5);
    assert(t[3].kind == T.int_ && t[4].kind == T.dotDot && t[5].kind == T.int_);
    assert(t[6].kind == T.int_ && t[7].kind == T.ident && t[7].id == "e");
    assert(t[8].kind == T.int_ && t[9].kind == T.ident && t[9].id == "e_5");
}

unittest
{
    auto t = lexString_(`"a\n\u{1F600}" '\'' '\u{e9}'`);
    assert(t[0].sval == "a\n\U0001F600"d);
    assert(t[1].ival == '\'');
    assert(t[2].ival == 0xE9);
}

unittest
{
    assert(lexError("0x_1") == Kind.badToken);
    assert(lexError("0x") == Kind.badToken);
    assert(lexError("9223372036854775808") == Kind.intRange);
    assert(lexError("\"ab\\q") == Kind.badEscape);
    assert(lexError("'ab'") == Kind.unterminated);
    assert(lexError("'\\q'") == Kind.badEscape);
    assert(lexError("/* /* */") == Kind.unterminated);
    assert(lexError("#x") == Kind.badToken);
    assert(lexError("é") == Kind.badToken);
}

unittest
{
    auto t = lexString_("a // c\n/* x /* y */ z */ b\n  c");
    assert(t.length == 4);
    assert(t[1].pos == Pos(2, 19));
    assert(t[2].pos == Pos(3, 3));
}
