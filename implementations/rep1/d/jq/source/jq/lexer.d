/// Tokenizer for filter text.
module jq.lexer;

import jq.error;
import jq.json : parseNumberText, unescape;

/// Token kinds.
enum Tok : ubyte
{
    eof,
    dot, // .
    field, // .name   (text = name)
    lbrack,
    rbrack,
    lparen,
    rparen,
    lbrace,
    rbrace,
    comma,
    pipe,
    colon,
    semi,
    question,
    plus,
    minus,
    star,
    slash,
    percent,
    eq,
    ne,
    lt,
    le,
    gt,
    ge,
    number,
    string_, // text = decoded contents
    ident, // text = name
    var, // $name, text = name
}

/// A token.
struct Token
{
    Tok kind;
    string text;
    double num;
    /// True when no whitespace precedes the token.
    bool adjacent;
    size_t pos;
}

private bool isIdentStart(char c) pure nothrow @nogc @safe
{
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_';
}

private bool isIdentChar(char c) pure nothrow @nogc @safe
{
    return isIdentStart(c) || (c >= '0' && c <= '9');
}

/// Splits `src` into tokens (the last one is `Tok.eof`).
Token[] tokenize(string src)
{
    Token[] toks;
    size_t i = 0;
    immutable n = src.length;
    bool ws = true;
    while (true)
    {
        // skip whitespace
        immutable before = i;
        while (i < n && (src[i] == ' ' || src[i] == '\t' || src[i] == '\n' || src[i] == '\r'))
            ++i;
        ws = i != before || i == 0;
        if (i >= n)
        {
            toks ~= Token(Tok.eof, "", 0, !ws, i);
            return toks;
        }
        immutable start = i;
        immutable c = src[i];
        void simple(Tok k, size_t len = 1)
        {
            toks ~= Token(k, "", 0, !ws, start);
            i += len;
        }

        immutable c2 = i + 1 < n ? src[i + 1] : '\0';
        switch (c)
        {
        case '.':
            if (isIdentStart(c2))
            {
                size_t j = i + 1;
                while (j < n && isIdentChar(src[j]))
                    ++j;
                toks ~= Token(Tok.field, src[i + 1 .. j], 0, !ws, start);
                i = j;
            }
            else
                simple(Tok.dot);
            break;
        case '[':
            simple(Tok.lbrack);
            break;
        case ']':
            simple(Tok.rbrack);
            break;
        case '(':
            simple(Tok.lparen);
            break;
        case ')':
            simple(Tok.rparen);
            break;
        case '{':
            simple(Tok.lbrace);
            break;
        case '}':
            simple(Tok.rbrace);
            break;
        case ',':
            simple(Tok.comma);
            break;
        case '|':
            simple(Tok.pipe);
            break;
        case ':':
            simple(Tok.colon);
            break;
        case ';':
            simple(Tok.semi);
            break;
        case '?':
            simple(Tok.question);
            break;
        case '+':
            simple(Tok.plus);
            break;
        case '-':
            simple(Tok.minus);
            break;
        case '*':
            simple(Tok.star);
            break;
        case '/':
            simple(Tok.slash);
            break;
        case '%':
            simple(Tok.percent);
            break;
        case '=':
            if (c2 != '=')
                throw new JqSyntaxError("unexpected '='");
            simple(Tok.eq, 2);
            break;
        case '!':
            if (c2 != '=')
                throw new JqSyntaxError("unexpected '!'");
            simple(Tok.ne, 2);
            break;
        case '<':
            if (c2 == '=')
                simple(Tok.le, 2);
            else
                simple(Tok.lt);
            break;
        case '>':
            if (c2 == '=')
                simple(Tok.ge, 2);
            else
                simple(Tok.gt);
            break;
        case '"':
            {
                size_t j = i + 1;
                while (j < n && src[j] != '"')
                {
                    if (src[j] == '\\')
                        ++j;
                    ++j;
                }
                if (j >= n)
                    throw new JqSyntaxError("unterminated string literal");
                toks ~= Token(Tok.string_, unescape(src[i + 1 .. j]), 0, !ws, start);
                i = j + 1;
                break;
            }
        case '$':
            {
                size_t j = i + 1;
                while (j < n && isIdentChar(src[j]))
                    ++j;
                if (j == i + 1)
                    throw new JqSyntaxError("expected a variable name after '$'");
                toks ~= Token(Tok.var, src[i + 1 .. j], 0, !ws, start);
                i = j;
                break;
            }
        default:
            if (c >= '0' && c <= '9')
            {
                size_t j = i;
                while (j < n && src[j] >= '0' && src[j] <= '9')
                    ++j;
                if (j + 1 < n && src[j] == '.' && src[j + 1] >= '0' && src[j + 1] <= '9')
                {
                    ++j;
                    while (j < n && src[j] >= '0' && src[j] <= '9')
                        ++j;
                }
                double d;
                if (!parseNumberText(src[i .. j], d))
                {
                    // e.g. a leading zero: fall back to the plain digits
                    d = 0;
                    foreach (ch; src[i .. j])
                        if (ch != '.')
                            d = d * 10 + (ch - '0');
                }
                toks ~= Token(Tok.number, src[i .. j], d, !ws, start);
                i = j;
            }
            else if (isIdentStart(c))
            {
                size_t j = i;
                while (j < n && isIdentChar(src[j]))
                    ++j;
                toks ~= Token(Tok.ident, src[i .. j], 0, !ws, start);
                i = j;
            }
            else
                throw new JqSyntaxError("unexpected character in filter");
        }
    }
}
