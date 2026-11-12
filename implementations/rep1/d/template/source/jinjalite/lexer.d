/// Splitting a template into text, `{{ }}` and `{% %}` items and tokenizing tag contents.
module jinjalite.lexer;

import std.array : appender;
import std.conv : to;
import std.string : indexOf;
import jinjalite.errors;

/// Token kinds inside a tag.
enum Tok : ubyte
{
    eof, name, integer, floating, string_,
    // keywords
    kwAnd, kwOr, kwNot, kwIn, kwIs, kwTrue, kwFalse, kwNone,
    // operators and punctuation
    pow, floorDiv, eq, ne, le, ge, tilde, plus, minus, star, slash, percent,
    lt, gt, lparen, rparen, lbracket, rbracket, comma, pipe, dot, assign,
}

/// One token of a tag.
struct Token
{
    /// The token kind.
    Tok kind;
    /// Identifier text, or the decoded contents of a string literal.
    string text;
    /// Value of an `integer` token.
    long intValue;
    /// Value of a `floating` token.
    double floatValue;
}

/// What a top-level piece of a template is.
enum ItemKind : ubyte { text, print, statement }

/// A top-level piece of a template: literal text, a `{{ }}` tag or a `{% %}` tag.
struct Item
{
    /// Which kind of piece this is.
    ItemKind kind;
    /// The literal text (for `text` items), after whitespace control.
    string text;
    /// The tokens of a tag, ending with an `eof` token.
    Token[] tokens;
    /// Byte offset of the piece in the template source (for error messages).
    size_t offset;
}

/// True for the six whitespace characters of the template language.
bool isWhitespace(char c) pure nothrow @safe @nogc
{
    return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f' || c == '\v';
}

private bool isNameStart(char c) pure nothrow @safe @nogc
{
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_';
}

private bool isDigit(char c) pure nothrow @safe @nogc
{
    return c >= '0' && c <= '9';
}

/// 1-based line number of byte `offset` in `src`.
size_t lineOf(string src, size_t offset) pure nothrow @safe @nogc
{
    size_t line = 1;
    foreach (c; src[0 .. offset < src.length ? offset : src.length])
        if (c == '\n')
            ++line;
    return line;
}

/++
    Split `src` into items, applying `-` whitespace control and dropping
    comments. Throws a `syntax` `TemplateError` for unclosed tags, bad
    characters and malformed string literals.
+/
Item[] scan(string src)
{
    Item[] items;
    const n = src.length;
    size_t pos = 0;
    bool trimNext = false; // previous tag ended with '-'

    void emitText(size_t from, size_t to, bool trimLeft, bool trimRight)
    {
        while (trimLeft && from < to && isWhitespace(src[from]))
            ++from;
        while (trimRight && to > from && isWhitespace(src[to - 1]))
            --to;
        if (from < to)
            items ~= Item(ItemKind.text, src[from .. to], null, from);
    }

    while (true)
    {
        // Find the next tag opener.
        size_t open = pos;
        while (open + 1 < n)
        {
            const c = src[open];
            if (c == '{')
            {
                const d = src[open + 1];
                if (d == '{' || d == '%' || d == '#')
                    break;
            }
            ++open;
        }
        if (open + 1 >= n)
        {
            emitText(pos, n, trimNext, false);
            break;
        }
        const type = src[open + 1];
        size_t p = open + 2;
        const stripBefore = p < n && src[p] == '-';
        if (stripBefore)
            ++p;
        emitText(pos, open, trimNext, stripBefore);

        if (type == '#')
        {
            const idx = src.indexOf("#}", p);
            if (idx < 0)
                syntaxError(posMessage(src, open, "unclosed comment"));
            trimNext = idx > cast(ptrdiff_t) p && src[idx - 1] == '-';
            pos = idx + 2;
        }
        else
        {
            const isPrint = type == '{';
            Token[] toks;
            bool stripAfter;
            pos = lexTag(src, p, isPrint, open, toks, stripAfter);
            items ~= Item(isPrint ? ItemKind.print : ItemKind.statement, null, toks, open);
            trimNext = stripAfter;
        }
    }
    return items;
}

private string posMessage(string src, size_t offset, string msg)
{
    return "line " ~ lineOf(src, offset).to!string ~ ": " ~ msg;
}

/// Tokenize the inside of a tag starting at `p`; returns the position after the closer.
private size_t lexTag(string src, size_t p, bool isPrint, size_t tagOffset, out Token[] toks, out bool stripAfter)
{
    const n = src.length;
    const closeCh = isPrint ? '}' : '%';
    Token[] result;
    while (true)
    {
        while (p < n && isWhitespace(src[p]))
            ++p;
        if (p >= n)
            syntaxError(posMessage(src, tagOffset, "unclosed tag"));
        const c = src[p];
        if (c == closeCh && p + 1 < n && src[p + 1] == '}')
        {
            stripAfter = false;
            p += 2;
            break;
        }
        if (c == '-' && p + 2 < n && src[p + 1] == closeCh && src[p + 2] == '}')
        {
            stripAfter = true;
            p += 3;
            break;
        }
        result ~= lexToken(src, p, tagOffset);
    }
    result ~= Token(Tok.eof);
    toks = result;
    return p;
}

private Token lexToken(string src, ref size_t p, size_t tagOffset)
{
    const n = src.length;
    const c = src[p];
    if (isNameStart(c))
    {
        const start = p;
        while (p < n && (isNameStart(src[p]) || isDigit(src[p])))
            ++p;
        const word = src[start .. p];
        Tok kind = Tok.name;
        switch (word)
        {
        case "and":   kind = Tok.kwAnd; break;
        case "or":    kind = Tok.kwOr; break;
        case "not":   kind = Tok.kwNot; break;
        case "in":    kind = Tok.kwIn; break;
        case "is":    kind = Tok.kwIs; break;
        case "true":  kind = Tok.kwTrue; break;
        case "false": kind = Tok.kwFalse; break;
        case "none":  kind = Tok.kwNone; break;
        default: break;
        }
        return Token(kind, word);
    }
    if (isDigit(c))
    {
        const start = p;
        ulong value = 0;
        while (p < n && isDigit(src[p]))
        {
            value = value * 10 + (src[p] - '0');
            ++p;
        }
        if (p + 1 < n && src[p] == '.' && isDigit(src[p + 1]))
        {
            ++p;
            while (p < n && isDigit(src[p]))
                ++p;
            Token t;
            t.kind = Tok.floating;
            t.floatValue = src[start .. p].to!double;
            return t;
        }
        Token t;
        t.kind = Tok.integer;
        t.intValue = cast(long) value;
        return t;
    }
    if (c == '"' || c == '\'')
        return lexString(src, p, tagOffset);

    Token op(Tok kind, size_t len)
    {
        p += len;
        return Token(kind);
    }
    const next = p + 1 < n ? src[p + 1] : '\0';
    switch (c)
    {
    case '*': return next == '*' ? op(Tok.pow, 2) : op(Tok.star, 1);
    case '/': return next == '/' ? op(Tok.floorDiv, 2) : op(Tok.slash, 1);
    case '=': return next == '=' ? op(Tok.eq, 2) : op(Tok.assign, 1);
    case '!':
        if (next == '=')
            return op(Tok.ne, 2);
        break;
    case '<': return next == '=' ? op(Tok.le, 2) : op(Tok.lt, 1);
    case '>': return next == '=' ? op(Tok.ge, 2) : op(Tok.gt, 1);
    case '~': return op(Tok.tilde, 1);
    case '+': return op(Tok.plus, 1);
    case '-': return op(Tok.minus, 1);
    case '%': return op(Tok.percent, 1);
    case '(': return op(Tok.lparen, 1);
    case ')': return op(Tok.rparen, 1);
    case '[': return op(Tok.lbracket, 1);
    case ']': return op(Tok.rbracket, 1);
    case ',': return op(Tok.comma, 1);
    case '|': return op(Tok.pipe, 1);
    case '.': return op(Tok.dot, 1);
    default: break;
    }
    syntaxError(posMessage(src, p, "unexpected character in tag"));
}

private Token lexString(string src, ref size_t p, size_t tagOffset)
{
    const n = src.length;
    const quote = src[p];
    ++p;
    const start = p;
    // Fast path: no escapes, so the token text is a slice of the source.
    while (p < n && src[p] != quote && src[p] != '\\')
        ++p;
    if (p >= n)
        syntaxError(posMessage(src, tagOffset, "unterminated string"));
    if (src[p] == quote)
    {
        auto t = Token(Tok.string_, src[start .. p]);
        ++p;
        return t;
    }
    auto buf = appender!(char[])();
    buf.put(src[start .. p]);
    while (true)
    {
        if (p >= n)
            syntaxError(posMessage(src, tagOffset, "unterminated string"));
        const c = src[p];
        if (c == quote)
        {
            ++p;
            return Token(Tok.string_, cast(string) buf.data);
        }
        if (c != '\\')
        {
            buf.put(c);
            ++p;
            continue;
        }
        ++p;
        if (p >= n)
            syntaxError(posMessage(src, tagOffset, "unterminated string"));
        switch (src[p])
        {
        case '\\': buf.put('\\'); break;
        case '"':  buf.put('"'); break;
        case '\'': buf.put('\''); break;
        case 'n':  buf.put('\n'); break;
        case 't':  buf.put('\t'); break;
        default:
            syntaxError(posMessage(src, p, "invalid escape in string literal"));
        }
        ++p;
    }
}

unittest
{
    auto items = scan("a {{ x }} b {% if y %}c{% endif %}{# note #}d");
    assert(items.length == 7);
    assert(items[0].kind == ItemKind.text && items[0].text == "a ");
    assert(items[1].kind == ItemKind.print);
    assert(items[1].tokens.length == 2 && items[1].tokens[0].text == "x");
    assert(items[3].kind == ItemKind.statement && items[3].tokens[0].text == "if");
    assert(items[6].text == "d");
}

unittest
{
    // Whitespace control only affects the adjacent text.
    auto items = scan("a  \n{%- if x -%}  \n b {{- y -}} \n c");
    assert(items[0].text == "a");
    assert(items[2].text == "b");
    assert(items[4].text == "c");
    // Comments honour it too.
    items = scan("a {#- c -#} b");
    assert(items.length == 2 && items[0].text == "a" && items[1].text == "b");
}

unittest
{
    import std.exception : assertThrown;
    // The closer is found by tokenizing, so strings may contain it.
    auto items = scan(`{{ "%}" ~ '}}' }}`);
    assert(items.length == 1 && items[0].tokens[0].text == "%}");
    assertThrown!TemplateError(scan("{{ x"));
    assertThrown!TemplateError(scan("{# x"));
    assertThrown!TemplateError(scan("{{{ x }}}"));
    assertThrown!TemplateError(scan(`{{ "a\q" }}`));
    assertThrown!TemplateError(scan(`{{ "abc }}`));
    assertThrown!TemplateError(scan("{{ a ! b }}"));
}

unittest
{
    auto items = scan(`{{ 1 + 2.5 ** 3 // 4 <= 5 != 6 }}`);
    const kinds = items[0].tokens;
    assert(kinds[0].kind == Tok.integer && kinds[0].intValue == 1);
    assert(kinds[2].kind == Tok.floating && kinds[2].floatValue == 2.5);
    assert(kinds[3].kind == Tok.pow);
    assert(kinds[5].kind == Tok.floorDiv);
    assert(kinds[7].kind == Tok.le);
    assert(kinds[9].kind == Tok.ne);
    // `-}}` closes the tag; `- }}` is a minus operator.
    assert(scan("{{ x -}}  y")[1].text == "y");
    assert(scan("{{ x - 1 -}}")[0].tokens[1].kind == Tok.minus);
}
