/**
 * The template lexer.
 *
 * A template source is split into $(LREF Item)s: literal text, `{{ }}` print
 * tags and `{% %}` statement tags.  Comments produce no item.  The contents
 * of tags are tokenized.  Whitespace control (`{{-`, `-}}`, ...) is applied
 * here, to the adjacent text items.
 */
module sitegen.templating.lexer;

import std.array : Appender;
import sitegen.templating.errors;
import sitegen.templating.value : parseDouble;

/// The kinds of token inside a tag.
enum TokKind : ubyte
{
    name,
    integer,
    floating,
    string_,
    op,
}

/// A token of a tag's content.
struct Token
{
    TokKind kind;
    /// The name, operator, or decoded string value.
    string text;
    long ival;
    double fval;
}

/// The kinds of top-level item of a template.
enum ItemKind : ubyte
{
    text,
    print,
    statement,
}

/// A piece of a template: text, or the tokens of one tag.
struct Item
{
    ItemKind kind;
    string text;
    Token[] tokens;
}

private bool isWs(char c) pure nothrow @nogc @safe
{
    return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f' || c == '\v';
}

private bool isNameStart(char c) pure nothrow @nogc @safe
{
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_';
}

private bool isDigit(char c) pure nothrow @nogc @safe
{
    return c >= '0' && c <= '9';
}

private string stripLeadingWs(string s) pure nothrow @nogc @safe
{
    size_t i = 0;
    while (i < s.length && isWs(s[i])) i++;
    return s[i .. $];
}

private string stripTrailingWs(string s) pure nothrow @nogc @safe
{
    size_t i = s.length;
    while (i > 0 && isWs(s[i - 1])) i--;
    return s[0 .. i];
}

/**
 * Splits `src` into items.
 *
 * Throws: `TemplateException` of kind `syntax` for an unterminated tag, a
 * bad token or a bad string escape.
 */
Item[] lex(string src)
{
    Item[] items;
    const n = src.length;
    size_t i = 0;
    bool stripNext = false;

    while (i < n)
    {
        // Find the next tag opener.
        size_t j = i;
        while (j + 1 < n && !(src[j] == '{' && (src[j + 1] == '{' || src[j + 1] == '%' || src[j + 1] == '#')))
            j++;
        if (j + 1 >= n)
        {
            auto t = src[i .. $];
            if (stripNext) t = stripLeadingWs(t);
            if (t.length) items ~= Item(ItemKind.text, t);
            break;
        }
        auto text = src[i .. j];
        const kindChar = src[j + 1];
        size_t k = j + 2;
        const openMinus = k < n && src[k] == '-';
        if (openMinus) k++;
        if (stripNext) text = stripLeadingWs(text);
        if (openMinus) text = stripTrailingWs(text);
        if (text.length) items ~= Item(ItemKind.text, text);

        if (kindChar == '#')
        {
            size_t e = k;
            while (e + 1 < n && !(src[e] == '#' && src[e + 1] == '}')) e++;
            if (e + 1 >= n) syntaxError("unclosed comment");
            stripNext = e > k && src[e - 1] == '-';
            i = e + 2;
            continue;
        }

        const isPrint = kindChar == '{';
        Token[] toks;
        bool closeMinus = false;
        bool closed = false;
        while (true)
        {
            while (k < n && isWs(src[k])) k++;
            if (k >= n) break;
            // Is this the closer?
            if (isPrint)
            {
                if (src[k] == '}' && k + 1 < n && src[k + 1] == '}')
                {
                    k += 2;
                    closed = true;
                    break;
                }
                if (src[k] == '-' && k + 2 < n && src[k + 1] == '}' && src[k + 2] == '}')
                {
                    k += 3;
                    closeMinus = true;
                    closed = true;
                    break;
                }
            }
            else
            {
                if (src[k] == '%' && k + 1 < n && src[k + 1] == '}')
                {
                    k += 2;
                    closed = true;
                    break;
                }
                if (src[k] == '-' && k + 2 < n && src[k + 1] == '%' && src[k + 2] == '}')
                {
                    k += 3;
                    closeMinus = true;
                    closed = true;
                    break;
                }
            }
            toks ~= lexToken(src, k);
        }
        if (!closed) syntaxError("unclosed tag");
        items ~= Item(isPrint ? ItemKind.print : ItemKind.statement, null, toks);
        stripNext = closeMinus;
        i = k;
    }
    return items;
}

/// Lexes one token starting at `k` (not whitespace) and advances `k`.
private Token lexToken(string src, ref size_t k)
{
    const n = src.length;
    const c = src[k];
    if (isNameStart(c))
    {
        const start = k;
        while (k < n && (isNameStart(src[k]) || isDigit(src[k]))) k++;
        return Token(TokKind.name, src[start .. k]);
    }
    if (isDigit(c))
    {
        const start = k;
        while (k < n && isDigit(src[k])) k++;
        if (k + 1 < n && src[k] == '.' && isDigit(src[k + 1]))
        {
            k++;
            while (k < n && isDigit(src[k])) k++;
            Token t;
            t.kind = TokKind.floating;
            t.text = src[start .. k];
            t.fval = parseDouble(t.text);
            return t;
        }
        Token t;
        t.kind = TokKind.integer;
        t.text = src[start .. k];
        long v = 0;
        foreach (ch; t.text) v = v * 10 + (ch - '0');
        t.ival = v;
        return t;
    }
    if (c == '"' || c == '\'')
    {
        k++;
        Appender!string o;
        while (true)
        {
            if (k >= n) syntaxError("unterminated string");
            const ch = src[k];
            if (ch == c)
            {
                k++;
                break;
            }
            if (ch == '\\')
            {
                if (k + 1 >= n) syntaxError("unterminated string");
                const e = src[k + 1];
                switch (e)
                {
                    case '\\': o.put('\\'); break;
                    case '"': o.put('"'); break;
                    case '\'': o.put('\''); break;
                    case 'n': o.put('\n'); break;
                    case 't': o.put('\t'); break;
                    default: syntaxError("bad string escape");
                }
                k += 2;
                continue;
            }
            o.put(ch);
            k++;
        }
        return Token(TokKind.string_, o.data);
    }
    // Operators: longest match first.
    if (k + 1 < n)
    {
        const two = src[k .. k + 2];
        switch (two)
        {
            case "**", "//", "==", "!=", "<=", ">=":
                k += 2;
                return Token(TokKind.op, two);
            default:
                break;
        }
    }
    switch (c)
    {
        case '~', '+', '-', '*', '/', '%', '<', '>', '(', ')', '[', ']', ',', '|', '.', '=':
            k++;
            return Token(TokKind.op, src[k - 1 .. k]);
        default:
            syntaxError("unexpected character in tag");
    }
}

unittest
{
    auto items = lex("a {{ x }} b {%- if y -%} c {# n #} d");
    assert(items.length == 6);
    assert(items[0].text == "a ");
    assert(items[1].kind == ItemKind.print);
    assert(items[2].text == " b");
    assert(items[3].kind == ItemKind.statement && items[3].tokens.length == 2);
    assert(items[4].text == "c ");
    assert(items[5].text == " d");
}

unittest
{
    auto items = lex(`{{ "a\"b" ~ 'c' }}{{ 1.5 ** 2 }}`);
    assert(items[0].tokens[0].text == "a\"b");
    assert(items[0].tokens[1].text == "~");
    assert(items[1].tokens[0].kind == TokKind.floating);
    assert(items[1].tokens[1].text == "**");
}

unittest
{
    import std.exception : collectException;

    foreach (bad; ["{{ x", "{# x", "{{ \"a }}", "{{ a $ b }}", "{{ \"\\q\" }}", "{{ x - }}x"])
    {
        auto e = collectException!TemplateException(lex(bad));
        // "{{ x - }}x" lexes fine (the parser rejects it); the rest are lexical errors.
        if (bad != "{{ x - }}x")
            assert(e !is null && e.kind == ErrorKind.syntax, bad);
    }
    auto items = lex("{{ x -}}  y");
    assert(items.length == 2 && items[1].text == "y");
}
