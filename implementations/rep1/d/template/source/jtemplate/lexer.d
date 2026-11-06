/// Single-pass lexer: splits a template body into text and tag segments and
/// tokenizes the content of each tag.
module jtemplate.lexer;

import core.stdc.stdlib : strtod;
import core.stdc.string : memchr;

import jtemplate.errors;

/// Token types inside a `{{ }}` or `{% %}` tag.
enum Tok : ubyte
{
    eof, name, integer, floating, str,
    pow, floorDiv, eq, ne, le, ge, tilde, plus, minus, star, slash, percent,
    lt, gt, lparen, rparen, lbracket, rbracket, comma, pipe, dot, assign,
    kwAnd, kwOr, kwNot, kwIn, kwIs, kwTrue, kwFalse, kwNone,
}

/// One token. `text` holds the identifier or the unescaped string value.
struct Token
{
    Tok type;      ///
    string text;   ///
    union
    {
        long ival;   /// value of an `integer` token
        double fval; /// value of a `floating` token
    }
}

/// Kinds of segments of a template.
enum SegKind : ubyte { text, print, stmt }

/// A piece of a template: literal text, or a tag whose tokens are
/// `tokens[tokBegin .. tokEnd]` of the [LexResult].
struct Segment
{
    SegKind kind;          ///
    string text;           /// for `text` segments
    uint tokBegin;         /// for tags
    uint tokEnd;           /// for tags
}

/// Output of [lex].
struct LexResult
{
    Segment[] segments;  ///
    Token[] tokens;      /// tokens of all tags, back to back
}

/// True for the six whitespace characters of the language.
bool isSpace(char c) pure nothrow @safe @nogc
{
    return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f' || c == '\v';
}

private bool isDigit(char c) pure nothrow @safe @nogc { return c >= '0' && c <= '9'; }

private bool isNameStart(char c) pure nothrow @safe @nogc
{
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_';
}

private Tok keywordType(const(char)[] s) pure nothrow @safe @nogc
{
    switch (s)
    {
        case "and":   return Tok.kwAnd;
        case "or":    return Tok.kwOr;
        case "not":   return Tok.kwNot;
        case "in":    return Tok.kwIn;
        case "is":    return Tok.kwIs;
        case "true":  return Tok.kwTrue;
        case "false": return Tok.kwFalse;
        case "none":  return Tok.kwNone;
        default:      return Tok.name;
    }
}

/// Find the next tag opener (`{{`, `{%` or `{#`) at or after `pos`;
/// returns `src.length` if there is none.
private size_t findOpener(string src, size_t pos) pure nothrow @trusted @nogc
{
    immutable n = src.length;
    while (pos + 1 < n)
    {
        auto p = cast(const(char)*) memchr(src.ptr + pos, '{', n - pos - 1);
        if (p is null)
            return n;
        immutable i = p - src.ptr;
        immutable c = src[i + 1];
        if (c == '{' || c == '%' || c == '#')
            return i;
        pos = i + 1;
    }
    return n;
}

/// Split `src` into segments and tokenize every tag.
///
/// Whitespace control (`{{-`, `-}}`, ...) is applied here by trimming the
/// adjacent text segments. Throws a syntax [TemplateError] for unclosed
/// tags and unlexable tag content.
LexResult lex(string src) pure @safe
{
    LexResult res;
    size_t pos = 0;
    bool stripNext = false;
    immutable n = src.length;

    for (;;)
    {
        immutable opener = findOpener(src, pos);
        size_t textBegin = pos, textEnd = opener;
        if (stripNext)
            while (textBegin < textEnd && isSpace(src[textBegin])) ++textBegin;
        stripNext = false;
        if (opener == n)
        {
            if (textBegin < textEnd)
                res.segments ~= Segment(SegKind.text, src[textBegin .. textEnd]);
            break;
        }

        immutable kindChar = src[opener + 1];
        size_t contentBegin = opener + 2;
        if (contentBegin < n && src[contentBegin] == '-')
        {
            ++contentBegin;
            while (textEnd > textBegin && isSpace(src[textEnd - 1])) --textEnd;
        }
        if (textBegin < textEnd)
            res.segments ~= Segment(SegKind.text, src[textBegin .. textEnd]);

        if (kindChar == '#')
        {
            size_t close = n;
            for (size_t i = contentBegin; i + 1 < n; ++i)
                if (src[i] == '#' && src[i + 1] == '}') { close = i; break; }
            if (close == n)
                throw syntaxError("unclosed comment");
            stripNext = close > contentBegin && src[close - 1] == '-';
            pos = close + 2;
            continue;
        }

        immutable isPrint = kindChar == '{';
        immutable tokBegin = cast(uint) res.tokens.length;
        bool rstrip;
        pos = lexTag(src, contentBegin, isPrint, res.tokens, rstrip);
        stripNext = rstrip;
        res.segments ~= Segment(isPrint ? SegKind.print : SegKind.stmt, null,
                                tokBegin, cast(uint) res.tokens.length);
    }
    return res;
}

/// Tokenize one tag starting at `i` (just after the opener and optional
/// `-`); returns the index after the closer.
private size_t lexTag(string src, size_t i, bool isPrint, ref Token[] toks, out bool rstrip) pure @safe
{
    immutable n = src.length;
    immutable closeChar = isPrint ? '}' : '%';
    for (;;)
    {
        while (i < n && isSpace(src[i])) ++i;
        if (i >= n)
            throw syntaxError("unclosed tag");
        immutable c = src[i];

        // The closer is checked before operators.
        if (c == '-' && i + 2 < n && src[i + 1] == closeChar && src[i + 2] == '}')
        {
            rstrip = true;
            return i + 3;
        }
        if (c == closeChar && i + 1 < n && src[i + 1] == '}')
            return i + 2;

        Token t;
        if (isNameStart(c))
        {
            size_t j = i + 1;
            while (j < n && (isNameStart(src[j]) || isDigit(src[j]))) ++j;
            t.text = src[i .. j];
            t.type = keywordType(t.text);
            i = j;
        }
        else if (isDigit(c))
        {
            size_t j = i + 1;
            while (j < n && isDigit(src[j])) ++j;
            if (j + 1 < n && src[j] == '.' && isDigit(src[j + 1]))
            {
                size_t k = j + 1;
                while (k < n && isDigit(src[k])) ++k;
                t.type = Tok.floating;
                t.fval = parseDouble(src[i .. k]);
                i = k;
            }
            else
            {
                t.type = Tok.integer;
                bool overflow;
                t.ival = parseInteger(src[i .. j], overflow);
                if (overflow)
                {
                    t.type = Tok.floating;
                    t.fval = parseDouble(src[i .. j]);
                }
                i = j;
            }
        }
        else if (c == '"' || c == '\'')
        {
            i = lexString(src, i, t);
        }
        else
        {
            immutable c2 = i + 1 < n ? src[i + 1] : '\0';
            Tok type;
            size_t len = 1;
            switch (c)
            {
                case '*': if (c2 == '*') { type = Tok.pow; len = 2; } else type = Tok.star; break;
                case '/': if (c2 == '/') { type = Tok.floorDiv; len = 2; } else type = Tok.slash; break;
                case '=': if (c2 == '=') { type = Tok.eq; len = 2; } else type = Tok.assign; break;
                case '!':
                    if (c2 == '=') { type = Tok.ne; len = 2; }
                    else throw syntaxError("unexpected '!'");
                    break;
                case '<': if (c2 == '=') { type = Tok.le; len = 2; } else type = Tok.lt; break;
                case '>': if (c2 == '=') { type = Tok.ge; len = 2; } else type = Tok.gt; break;
                case '~': type = Tok.tilde; break;
                case '+': type = Tok.plus; break;
                case '-': type = Tok.minus; break;
                case '%': type = Tok.percent; break;
                case '(': type = Tok.lparen; break;
                case ')': type = Tok.rparen; break;
                case '[': type = Tok.lbracket; break;
                case ']': type = Tok.rbracket; break;
                case ',': type = Tok.comma; break;
                case '|': type = Tok.pipe; break;
                case '.': type = Tok.dot; break;
                default: throw syntaxError("unexpected character in tag");
            }
            t.type = type;
            i += len;
        }
        toks ~= t;
    }
}

private long parseInteger(const(char)[] digits, out bool overflow) pure nothrow @safe @nogc
{
    ulong v = 0;
    foreach (ch; digits)
    {
        immutable d = ch - '0';
        if (v > (long.max - d) / 10)
        {
            overflow = true;
            return 0;
        }
        v = v * 10 + d;
    }
    return cast(long) v;
}

private double parseDouble(const(char)[] text) pure @trusted
{
    import std.conv : to;
    return to!double(text);
}

/// Lex a string literal starting at the opening quote `src[i]`.
private size_t lexString(string src, size_t i, ref Token t) pure @safe
{
    immutable n = src.length;
    immutable quote = src[i];
    size_t j = i + 1;
    bool escaped = false;
    while (j < n && src[j] != quote)
    {
        if (src[j] == '\\')
        {
            escaped = true;
            ++j;
            if (j >= n) break;
            switch (src[j])
            {
                case '\\', '"', '\'', 'n', 't': break;
                default: throw syntaxError("bad escape in string");
            }
        }
        ++j;
    }
    if (j >= n)
        throw syntaxError("unterminated string");
    t.type = Tok.str;
    if (!escaped)
    {
        t.text = src[i + 1 .. j];
    }
    else
    {
        char[] buf;
        buf.reserve(j - i);
        for (size_t k = i + 1; k < j; ++k)
        {
            char ch = src[k];
            if (ch == '\\')
            {
                ++k;
                switch (src[k])
                {
                    case 'n': ch = '\n'; break;
                    case 't': ch = '\t'; break;
                    default:  ch = src[k]; break;
                }
            }
            buf ~= ch;
        }
        t.text = buf.idup;
    }
    return j + 1;
}
