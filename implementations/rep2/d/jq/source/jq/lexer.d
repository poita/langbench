/// Tokenizer for the filter language.
module jq.lexer;

import jq.errors : FilterSyntaxError, JsonException;
import jq.json : unescapeJsonString, tryParseNumber;

/// Token categories.
enum TokKind : ubyte
{
    number,
    string,
    ident, /// identifiers and keywords
    variable, /// `$name` (text is the name without `$`)
    punct, /// operators and punctuation (text is the symbol)
    eof,
}

/// A token.
struct Token
{
    TokKind kind;
    string text;
    double num;
    size_t pos;
}

private bool isIdentStart(char c) @safe pure nothrow @nogc
{
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_';
}

private bool isDigit(char c) @safe pure nothrow @nogc
{
    return c >= '0' && c <= '9';
}

/// Splits a filter program into tokens (the last token is always `eof`).
Token[] tokenize(string src)
{
    Token[] toks;
    size_t i = 0;
    while (i < src.length)
    {
        immutable c = src[i];
        if (c == ' ' || c == '\t' || c == '\n' || c == '\r')
        {
            i++;
            continue;
        }
        immutable start = i;
        if (isDigit(c))
        {
            while (i < src.length && isDigit(src[i]))
                i++;
            if (i + 1 < src.length && src[i] == '.' && isDigit(src[i + 1]))
            {
                i++;
                while (i < src.length && isDigit(src[i]))
                    i++;
            }
            double d;
            if (!tryParseNumber(src[start .. i], d))
            {
                // e.g. leading zeros: fall back to plain conversion
                import std.conv : to;

                d = src[start .. i].to!double;
            }
            toks ~= Token(TokKind.number, src[start .. i], d, start);
        }
        else if (isIdentStart(c))
        {
            while (i < src.length && (isIdentStart(src[i]) || isDigit(src[i])))
                i++;
            toks ~= Token(TokKind.ident, src[start .. i], 0, start);
        }
        else if (c == '$')
        {
            i++;
            immutable ns = i;
            while (i < src.length && (isIdentStart(src[i]) || isDigit(src[i])))
                i++;
            if (i == ns)
                throw new FilterSyntaxError("expected variable name after '$'");
            toks ~= Token(TokKind.variable, src[ns .. i], 0, start);
        }
        else if (c == '"')
        {
            i++;
            bool escaped = false;
            while (true)
            {
                if (i >= src.length)
                    throw new FilterSyntaxError("unterminated string literal");
                if (src[i] == '"')
                    break;
                if (src[i] == '\\')
                {
                    escaped = true;
                    i++;
                }
                i++;
            }
            auto body_ = src[start + 1 .. i];
            i++;
            string text;
            try
                text = escaped ? unescapeJsonString(body_) : body_;
            catch (JsonException e)
                throw new FilterSyntaxError("bad string literal: " ~ e.msg);
            toks ~= Token(TokKind.string, text, 0, start);
        }
        else
        {
            string p;
            if (i + 1 < src.length)
            {
                auto two = src[i .. i + 2];
                if (two == "==" || two == "!=" || two == "<=" || two == ">=")
                    p = two;
            }
            if (p.length == 0)
            {
                switch (c)
                {
                case '.', ',', '|', '(', ')', '[', ']', '{', '}', ':', ';', '?',
                        '+', '-', '*', '/', '%', '<', '>':
                        p = src[i .. i + 1];
                    break;
                default:
                    throw new FilterSyntaxError("unexpected character '" ~ c ~ "'");
                }
            }
            i += p.length;
            toks ~= Token(TokKind.punct, p, 0, start);
        }
    }
    toks ~= Token(TokKind.eof, "", 0, src.length);
    return toks;
}

unittest
{
    auto t = tokenize(`.a[0] | "x\ty" >= $v1 , 1.5`);
    string[] texts;
    foreach (x; t)
        texts ~= x.text;
    assert(texts == [".", "a", "[", "0", "]", "|", "x\ty", ">=", "v1", ",", "1.5", ""]);
    assert(t[$ - 2].num == 1.5);
    assert(t[$ - 1].kind == TokKind.eof);
}
