/// Splits template source into text and tag items, and tags into tokens.
module sitegen.templating.lexer;

import sitegen.templating.errors;
import sitegen.templating.value : parseDouble;

/// Token categories inside a tag.
enum TokKind : ubyte
{
    name,
    integer,
    floating,
    str,
    op,
}

/// One token of a tag.
struct Token
{
    TokKind kind;
    string text; /// name, operator, or decoded string contents
    long ival;
    double fval;
}

/// Item categories of a template.
enum ItemKind : ubyte
{
    text,
    print,
    stmt,
}

/// A piece of a template: literal text or a tokenized tag.
struct Item
{
    ItemKind kind;
    string text;
    Token[] tokens;
}

private bool isWs(char c) pure nothrow @safe @nogc
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

private string trimLeft(string s) pure nothrow @safe @nogc
{
    size_t i = 0;
    while (i < s.length && isWs(s[i]))
        ++i;
    return s[i .. $];
}

private string trimRight(string s) pure nothrow @safe @nogc
{
    size_t n = s.length;
    while (n > 0 && isWs(s[n - 1]))
        --n;
    return s[0 .. n];
}

private bool startsWithAt(string s, size_t i, string lit) pure nothrow @safe @nogc
{
    return s.length - i >= lit.length && s[i .. i + lit.length] == lit;
}

/// Split `src` into items, applying whitespace control. Throws a `syntax`
/// error for unterminated tags and untokenizable tag content.
Item[] lexTemplate(string src)
{
    Item[] items;
    size_t pos = 0;
    bool stripNext = false;
    while (true)
    {
        // find the next tag opener
        size_t found = size_t.max;
        for (size_t i = pos; i + 1 < src.length; ++i)
        {
            if (src[i] != '{')
                continue;
            immutable n = src[i + 1];
            if (n == '{' || n == '%' || n == '#')
            {
                found = i;
                break;
            }
        }
        string text = src[pos .. found == size_t.max ? src.length : found];
        if (stripNext)
            text = trimLeft(text);
        size_t contentStart;
        bool lstrip = false;
        if (found != size_t.max)
        {
            contentStart = found + 2;
            if (contentStart < src.length && src[contentStart] == '-')
            {
                lstrip = true;
                ++contentStart;
            }
            if (lstrip)
                text = trimRight(text);
        }
        if (text.length)
            items ~= Item(ItemKind.text, text);
        if (found == size_t.max)
            break;

        immutable opener = src[found + 1];
        stripNext = false;
        if (opener == '#')
        {
            size_t end = contentStart;
            bool ok = false;
            for (; end + 1 < src.length; ++end)
                if (src[end] == '#' && src[end + 1] == '}')
                {
                    ok = true;
                    break;
                }
            if (!ok)
                throw syntaxError("unclosed comment");
            stripNext = end > contentStart && src[end - 1] == '-';
            pos = end + 2;
            continue;
        }
        bool rstrip;
        size_t after;
        auto tokens = lexTag(src, contentStart, opener == '{', rstrip, after);
        items ~= Item(opener == '{' ? ItemKind.print : ItemKind.stmt, null, tokens);
        stripNext = rstrip;
        pos = after;
    }
    return items;
}

/// Tokenize one tag whose content starts at `start`. Sets `rstrip` when the
/// closer had a `-` and `after` to the index following the closer.
private Token[] lexTag(string src, size_t start, bool isPrint, out bool rstrip, out size_t after)
{
    Token[] toks;
    size_t i = start;
    immutable closer = isPrint ? "}}" : "%}";
    immutable closerDash = isPrint ? "-}}" : "-%}";
    while (true)
    {
        while (i < src.length && isWs(src[i]))
            ++i;
        if (i >= src.length)
            throw syntaxError("unclosed tag");
        if (startsWithAt(src, i, closerDash))
        {
            rstrip = true;
            after = i + 3;
            return toks;
        }
        if (startsWithAt(src, i, closer))
        {
            rstrip = false;
            after = i + 2;
            return toks;
        }
        immutable c = src[i];
        Token t;
        if (isNameStart(c))
        {
            size_t j = i + 1;
            while (j < src.length && (isNameStart(src[j]) || isDigit(src[j])))
                ++j;
            t.kind = TokKind.name;
            t.text = src[i .. j];
            i = j;
        }
        else if (isDigit(c))
        {
            size_t j = i;
            while (j < src.length && isDigit(src[j]))
                ++j;
            if (j + 1 < src.length && src[j] == '.' && isDigit(src[j + 1]))
            {
                size_t k = j + 1;
                while (k < src.length && isDigit(src[k]))
                    ++k;
                t.kind = TokKind.floating;
                t.fval = parseDouble(src[i .. k]);
                j = k;
            }
            else
            {
                long v = 0;
                foreach (ch; src[i .. j])
                    v = v * 10 + (ch - '0');
                t.kind = TokKind.integer;
                t.ival = v;
            }
            t.text = src[i .. j];
            i = j;
        }
        else if (c == '"' || c == '\'')
        {
            t.kind = TokKind.str;
            t.text = lexString(src, i);
        }
        else
        {
            t.kind = TokKind.op;
            static immutable string[6] two = ["**", "//", "==", "!=", "<=", ">="];
            string op;
            foreach (cand; two)
                if (startsWithAt(src, i, cand))
                {
                    op = cand;
                    break;
                }
            if (op is null)
            {
                switch (c)
                {
                case '~': op = "~"; break;
                case '+': op = "+"; break;
                case '-': op = "-"; break;
                case '*': op = "*"; break;
                case '/': op = "/"; break;
                case '%': op = "%"; break;
                case '<': op = "<"; break;
                case '>': op = ">"; break;
                case '(': op = "("; break;
                case ')': op = ")"; break;
                case '[': op = "["; break;
                case ']': op = "]"; break;
                case ',': op = ","; break;
                case '|': op = "|"; break;
                case '.': op = "."; break;
                case '=': op = "="; break;
                default:
                    throw syntaxError("unexpected character in tag");
                }
            }
            t.text = op;
            i += op.length;
        }
        toks ~= t;
    }
}

/// Lex the string literal opening at `src[i]`; advances `i` past it.
private string lexString(string src, ref size_t i)
{
    immutable quote = src[i];
    ++i;
    size_t runStart = i;
    char[] buf;
    bool escaped = false;
    while (true)
    {
        if (i >= src.length)
            throw syntaxError("unterminated string");
        immutable c = src[i];
        if (c == quote)
            break;
        if (c != '\\')
        {
            ++i;
            continue;
        }
        escaped = true;
        buf ~= src[runStart .. i];
        ++i;
        if (i >= src.length)
            throw syntaxError("unterminated string");
        switch (src[i])
        {
        case '\\': buf ~= '\\'; break;
        case '"': buf ~= '"'; break;
        case '\'': buf ~= '\''; break;
        case 'n': buf ~= '\n'; break;
        case 't': buf ~= '\t'; break;
        default:
            throw syntaxError("bad string escape");
        }
        ++i;
        runStart = i;
    }
    string result;
    if (escaped)
    {
        buf ~= src[runStart .. i];
        result = buf.idup;
    }
    else
        result = src[runStart .. i];
    ++i;
    return result;
}
