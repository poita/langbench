/// Lexical analysis of Vellum source text.
module langvm.lexer;

import langvm.diag;
import langvm.source;
import core.stdc.stdlib : strtod;

/// Token kinds.
enum Tk : ubyte
{
    eof, ident, intLit, floatLit, strLit, charLit,
    // keywords
    kwAs, kwBreak, kwContinue, kwElse, kwEnum, kwFalse, kwFn, kwFor, kwIf, kwImpl,
    kwIn, kwLet, kwMatch, kwPub, kwReturn, kwSelf, kwStruct, kwTrait, kwTrue, kwUse,
    kwVar, kwWhen, kwWhile,
    // punctuation
    hashBracket, colonColon, dotDot, arrow, eqEq, notEq, ltEq, gtEq, andAnd, orOr,
    shl, shr, plusPlus, lParen, rParen, lBracket, rBracket, lBrace, rBrace, comma,
    semi, colon, dot, pipe, plus, minus, star, slash, percent, bang, tilde, amp,
    caret, lt, gt, assign, underscore,
}

/// A lexical token.
struct Token
{
    /// The kind of token.
    Tk kind;
    /// Position of the first character.
    Pos pos;
    /// Identifier text (for `ident`).
    string text;
    /// Value of an integer literal or character literal.
    long ival;
    /// Value of a float literal.
    double fval;
    /// Value of a string literal.
    dstring sval;
}

/// Human-readable spelling of a punctuation/keyword token kind (used by tests and debugging).
string tokenName(Tk k)
{
    import std.conv : to;

    return k.to!string;
}

private Tk keywordKind(const(char)[] s)
{
    switch (s)
    {
    case "as": return Tk.kwAs;
    case "break": return Tk.kwBreak;
    case "continue": return Tk.kwContinue;
    case "else": return Tk.kwElse;
    case "enum": return Tk.kwEnum;
    case "false": return Tk.kwFalse;
    case "fn": return Tk.kwFn;
    case "for": return Tk.kwFor;
    case "if": return Tk.kwIf;
    case "impl": return Tk.kwImpl;
    case "in": return Tk.kwIn;
    case "let": return Tk.kwLet;
    case "match": return Tk.kwMatch;
    case "pub": return Tk.kwPub;
    case "return": return Tk.kwReturn;
    case "self": return Tk.kwSelf;
    case "struct": return Tk.kwStruct;
    case "trait": return Tk.kwTrait;
    case "true": return Tk.kwTrue;
    case "use": return Tk.kwUse;
    case "var": return Tk.kwVar;
    case "when": return Tk.kwWhen;
    case "while": return Tk.kwWhile;
    default: return Tk.eof;
    }
}

private bool isDigit(dchar c) pure nothrow @safe @nogc
{
    return c >= '0' && c <= '9';
}

private bool isHex(dchar c) pure nothrow @safe @nogc
{
    return isDigit(c) || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
}

private int hexVal(dchar c) pure nothrow @safe @nogc
{
    if (isDigit(c))
        return c - '0';
    if (c >= 'a' && c <= 'f')
        return c - 'a' + 10;
    return c - 'A' + 10;
}

private bool isIdStart(dchar c) pure nothrow @safe @nogc
{
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_';
}

private bool isIdChar(dchar c) pure nothrow @safe @nogc
{
    return isIdStart(c) || isDigit(c);
}

/// Converts decimal float text (digits, optional `.`, exponent) to the nearest binary64 value.
double parseDecimalDouble(const(char)[] text)
{
    import std.string : toStringz;

    return strtod(toStringz(text), null);
}

/// The lexer for one module body.
struct Lexer
{
    private dstring src;
    private size_t i;
    private int line = 1;
    private int col = 1;

    /// Lexes `lines` (the body of one module) into a token array ending with `eof`.
    /// Throws: [CompileError] for the first ill-formed token.
    static Token[] lex(const(dstring)[] lines)
    {
        dstring text;
        size_t total = 0;
        foreach (l; lines)
            total += l.length + 1;
        text.reserve(total);
        foreach (k, l; lines)
        {
            if (k > 0)
                text ~= '\n';
            text ~= l;
        }
        Lexer lx;
        lx.src = text;
        Token[] toks;
        toks.reserve(text.length / 3 + 4);
        lx.run(toks);
        // end-of-input position: last line of the module, one past its length
        Token e;
        e.kind = Tk.eof;
        int ln = lines.length == 0 ? 1 : cast(int) lines.length;
        int cl = lines.length == 0 ? 1 : cast(int) lines[$ - 1].length + 1;
        e.pos = Pos(ln, cl);
        toks ~= e;
        return toks;
    }

    private bool atEnd() const
    {
        return i >= src.length;
    }

    private dchar peek(size_t off = 0) const
    {
        return i + off < src.length ? src[i + off] : dchar.init;
    }

    private bool has(size_t off = 0) const
    {
        return i + off < src.length;
    }

    private void adv()
    {
        if (src[i] == '\n')
        {
            line++;
            col = 1;
        }
        else
            col++;
        i++;
    }

    private Pos here() const
    {
        return Pos(line, col);
    }

    private void run(ref Token[] toks)
    {
        while (true)
        {
            // skip whitespace and comments
            while (has())
            {
                dchar c = peek();
                if (c == ' ' || c == '\t' || c == '\n' || c == '\r')
                    adv();
                else if (c == '/' && has(1) && peek(1) == '/')
                {
                    while (has() && peek() != '\n')
                        adv();
                }
                else if (c == '/' && has(1) && peek(1) == '*')
                {
                    Pos start = here();
                    adv();
                    adv();
                    int depth = 1;
                    while (depth > 0)
                    {
                        if (!has())
                            fail("unterminated", start);
                        if (peek() == '/' && has(1) && peek(1) == '*')
                        {
                            adv();
                            adv();
                            depth++;
                        }
                        else if (peek() == '*' && has(1) && peek(1) == '/')
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
                    break;
            }
            if (!has())
                return;
            toks ~= next();
        }
    }

    private Token punct(Tk k, int n)
    {
        Token t;
        t.kind = k;
        t.pos = here();
        foreach (_; 0 .. n)
            adv();
        return t;
    }

    private Token next()
    {
        dchar c = peek();
        Pos start = here();
        if (isDigit(c))
            return number();
        if (isIdStart(c))
        {
            size_t b = i;
            while (has() && isIdChar(peek()))
                adv();
            size_t len = i - b;
            if (len > 200)
                fail("bad-token", start);
            char[] buf = new char[len];
            foreach (k; 0 .. len)
                buf[k] = cast(char) src[b + k];
            string s = cast(string) buf;
            Token t;
            t.pos = start;
            if (s == "_")
            {
                t.kind = Tk.underscore;
                return t;
            }
            Tk kw = keywordKind(s);
            if (kw != Tk.eof)
            {
                t.kind = kw;
                return t;
            }
            t.kind = Tk.ident;
            t.text = s;
            return t;
        }
        if (c == '"')
            return stringLit();
        if (c == '\'')
            return charLit();
        dchar d = peek(1);
        bool has1 = has(1);
        switch (c)
        {
        case '#':
            if (has1 && d == '[')
                return punct(Tk.hashBracket, 2);
            fail("bad-token", start);
        case ':':
            return has1 && d == ':' ? punct(Tk.colonColon, 2) : punct(Tk.colon, 1);
        case '.':
            return has1 && d == '.' ? punct(Tk.dotDot, 2) : punct(Tk.dot, 1);
        case '-':
            return has1 && d == '>' ? punct(Tk.arrow, 2) : punct(Tk.minus, 1);
        case '=':
            return has1 && d == '=' ? punct(Tk.eqEq, 2) : punct(Tk.assign, 1);
        case '!':
            return has1 && d == '=' ? punct(Tk.notEq, 2) : punct(Tk.bang, 1);
        case '<':
            if (has1 && d == '=')
                return punct(Tk.ltEq, 2);
            if (has1 && d == '<')
                return punct(Tk.shl, 2);
            return punct(Tk.lt, 1);
        case '>':
            if (has1 && d == '=')
                return punct(Tk.gtEq, 2);
            if (has1 && d == '>')
                return punct(Tk.shr, 2);
            return punct(Tk.gt, 1);
        case '&':
            return has1 && d == '&' ? punct(Tk.andAnd, 2) : punct(Tk.amp, 1);
        case '|':
            return has1 && d == '|' ? punct(Tk.orOr, 2) : punct(Tk.pipe, 1);
        case '+':
            return has1 && d == '+' ? punct(Tk.plusPlus, 2) : punct(Tk.plus, 1);
        case '(':
            return punct(Tk.lParen, 1);
        case ')':
            return punct(Tk.rParen, 1);
        case '[':
            return punct(Tk.lBracket, 1);
        case ']':
            return punct(Tk.rBracket, 1);
        case '{':
            return punct(Tk.lBrace, 1);
        case '}':
            return punct(Tk.rBrace, 1);
        case ',':
            return punct(Tk.comma, 1);
        case ';':
            return punct(Tk.semi, 1);
        case '*':
            return punct(Tk.star, 1);
        case '/':
            return punct(Tk.slash, 1);
        case '%':
            return punct(Tk.percent, 1);
        case '~':
            return punct(Tk.tilde, 1);
        case '^':
            return punct(Tk.caret, 1);
        default:
            fail("bad-token", start);
        }
    }

    /// Consumes digits and `_` (a run that starts with a digit); appends digits (not `_`) to `buf`.
    private void digitRun(ref char[] buf, bool function(dchar) pure nothrow @safe @nogc isD)
    {
        while (has() && (isD(peek()) || peek() == '_'))
        {
            if (peek() != '_')
                buf ~= cast(char) peek();
            adv();
        }
    }

    private Token number()
    {
        Pos start = here();
        Token t;
        t.pos = start;
        if (peek() == '0' && has(1) && (peek(1) == 'x' || peek(1) == 'b'))
        {
            bool hex = peek(1) == 'x';
            bool function(dchar) pure nothrow @safe @nogc isD = hex ? &isHex : (dchar ch) => ch == '0' || ch == '1';
            if (!(has(2) && isD(peek(2))))
                fail("bad-token", start);
            adv();
            adv();
            ulong v = 0;
            bool over = false;
            ulong base = hex ? 16 : 2;
            while (has() && (isD(peek()) || peek() == '_'))
            {
                if (peek() != '_')
                {
                    ulong dv = hexVal(peek());
                    if (v > (ulong(long.max) - dv) / base)
                        over = true;
                    else
                        v = v * base + dv;
                }
                adv();
            }
            if (over)
                fail("int-range", start);
            t.kind = Tk.intLit;
            t.ival = cast(long) v;
            return t;
        }
        char[] buf;
        digitRun(buf, &isDigit);
        bool isFloat = false;
        if (has() && peek() == '.' && has(1) && isDigit(peek(1)))
        {
            adv();
            buf ~= '.';
            digitRun(buf, &isDigit);
            isFloat = true;
        }
        if (has() && (peek() == 'e' || peek() == 'E'))
        {
            size_t off = 1;
            if (has(off) && (peek(off) == '+' || peek(off) == '-'))
                off++;
            if (has(off) && isDigit(peek(off)))
            {
                buf ~= 'e';
                adv();
                if (peek() == '+' || peek() == '-')
                {
                    buf ~= cast(char) peek();
                    adv();
                }
                digitRun(buf, &isDigit);
                isFloat = true;
            }
        }
        if (isFloat)
        {
            t.kind = Tk.floatLit;
            t.fval = parseDecimalDouble(buf);
            return t;
        }
        ulong v = 0;
        foreach (ch; buf)
        {
            ulong dv = ch - '0';
            if (v > (ulong(long.max) - dv) / 10)
                fail("int-range", start);
            v = v * 10 + dv;
        }
        t.kind = Tk.intLit;
        t.ival = cast(long) v;
        return t;
    }

    /// Reads an escape sequence; the backslash is at the current position.
    private dchar escape()
    {
        Pos bs = here();
        adv(); // backslash
        if (!has())
            fail("bad-escape", bs);
        dchar c = peek();
        adv();
        switch (c)
        {
        case 'n':
            return '\n';
        case 't':
            return '\t';
        case 'r':
            return '\r';
        case '0':
            return '\0';
        case '\\':
            return '\\';
        case '\'':
            return '\'';
        case '"':
            return '"';
        case 'u':
            if (!has() || peek() != '{')
                fail("bad-escape", bs);
            adv();
            uint v = 0;
            int n = 0;
            while (has() && isHex(peek()))
            {
                if (n < 7)
                    v = v * 16 + hexVal(peek());
                n++;
                adv();
            }
            if (n < 1 || n > 6 || !has() || peek() != '}')
                fail("bad-escape", bs);
            adv();
            if (v > 0x10FFFF || (v >= 0xD800 && v <= 0xDFFF))
                fail("bad-escape", bs);
            return cast(dchar) v;
        default:
            fail("bad-escape", bs);
        }
    }

    private Token charLit()
    {
        Pos start = here();
        adv();
        Token t;
        t.pos = start;
        t.kind = Tk.charLit;
        if (!has())
            fail("unterminated", start);
        dchar c = peek();
        dchar v;
        if (c == '\\')
            v = escape();
        else if (c == '\'' || c == '\n' || c == '\r')
            fail("unterminated", start);
        else
        {
            v = c;
            adv();
        }
        if (!has() || peek() != '\'')
            fail("unterminated", start);
        adv();
        t.ival = v;
        return t;
    }

    private Token stringLit()
    {
        Pos start = here();
        adv();
        Token t;
        t.pos = start;
        t.kind = Tk.strLit;
        dchar[] buf;
        while (true)
        {
            if (!has())
                fail("unterminated", start);
            dchar c = peek();
            if (c == '"')
            {
                adv();
                break;
            }
            if (c == '\n' || c == '\r')
                fail("unterminated", start);
            if (c == '\\')
                buf ~= escape();
            else
            {
                buf ~= c;
                adv();
            }
        }
        t.sval = cast(dstring) buf;
        return t;
    }
}
