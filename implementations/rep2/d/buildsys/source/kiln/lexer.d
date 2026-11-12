/**
 * The KBL lexer: comment stripping, logical-line assembly and tokenisation.
 *
 * All three stages share one $(I literal scanner) ($(LREF skipLiteral)) so
 * they can never disagree about what lies inside a string literal.
 */
module kiln.lexer;

import kiln.errors : failParse;

/// Token kinds.
enum TokenKind : ubyte
{
    identifier,
    integer,
    str, /// A string literal; see `Token.text`, `Token.doubleQuoted`.
    punct, /// `( ) [ ] { } , =`
    op, /// every operator
}

/// A lexical token.
struct Token
{
    TokenKind kind;
    /// Identifier or operator/punctuation spelling; for strings the raw
    /// text between the quotes (escapes not yet processed).
    string text;
    /// Value of an integer token.
    long intValue;
    /// For strings: whether it is a double-quoted literal.
    bool doubleQuoted;

    /// True for a punctuation or operator token spelled `s`.
    bool isSym(string s) const @safe pure nothrow @nogc
    {
        return (kind == TokenKind.punct || kind == TokenKind.op) && text == s;
    }

    /// True for an identifier spelled `s`.
    bool isWord(string s) const @safe pure nothrow @nogc
    {
        return kind == TokenKind.identifier && text == s;
    }
}

/// A logical line: its first physical line number and its tokens.
struct LogicalLine
{
    int number;
    Token[] tokens;
}

/// Thrown for a syntax error whose line is attached by the caller.
class SyntaxFailure : Exception
{
    this(string file = __FILE__, size_t line = __LINE__) @safe pure nothrow @nogc
    {
        super("syntax error", file, line);
    }
}

/// The reserved words.
bool isReserved(const(char)[] s) @safe pure nothrow @nogc
{
    switch (s)
    {
    case "abort", "after", "cmd", "cost", "default", "depfile", "each", "elsewhen",
            "false", "in", "include", "let", "otherwise", "out", "phony", "rule",
            "set", "step", "true", "use", "when":
        return true;
    default:
        return false;
    }
}

/// Whether `s` has the shape `[A-Za-z_][A-Za-z0-9_]*`.
bool isIdentShaped(const(char)[] s) @safe pure nothrow @nogc
{
    if (s.length == 0 || !isIdentStart(s[0]))
        return false;
    foreach (c; s[1 .. $])
        if (!isIdentChar(c))
            return false;
    return true;
}

private bool isIdentStart(char c) @safe pure nothrow @nogc
{
    return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || c == '_';
}

private bool isIdentChar(char c) @safe pure nothrow @nogc
{
    return isIdentStart(c) || (c >= '0' && c <= '9');
}

/**
 * The literal scanner. `s[i]` must be a quote. Returns the index just past the
 * closing quote, or -1 when the literal is unterminated.
 */
ptrdiff_t skipLiteral(const(char)[] s, size_t i) @safe pure nothrow @nogc
{
    immutable q = s[i];
    i++;
    if (q == '\'')
    {
        while (i < s.length)
        {
            if (s[i] == '\'')
            {
                if (i + 1 < s.length && s[i + 1] == '\'')
                {
                    i += 2;
                    continue;
                }
                return cast(ptrdiff_t)(i + 1);
            }
            i++;
        }
        return -1;
    }
    while (i < s.length)
    {
        immutable c = s[i];
        if (c == '\\')
        {
            i += 2;
        }
        else if (c == '{')
        {
            if (i + 1 < s.length && s[i + 1] == '{')
            {
                i += 2;
                continue;
            }
            immutable end = skipInterpolation(s, i + 1);
            if (end < 0)
                return -1;
            i = cast(size_t) end;
        }
        else if (c == '"')
        {
            return cast(ptrdiff_t)(i + 1);
        }
        else
        {
            i++;
        }
    }
    return -1;
}

/**
 * Scans an interpolation region whose body starts at `i`; returns the index
 * just past the closing `}`, or -1 if the region is not closed.
 */
ptrdiff_t skipInterpolation(const(char)[] s, size_t i) @safe pure nothrow @nogc
{
    size_t depth = 1;
    while (i < s.length)
    {
        immutable c = s[i];
        if (c == '"' || c == '\'')
        {
            immutable e = skipLiteral(s, i);
            if (e < 0)
                return -1;
            i = cast(size_t) e;
        }
        else if (c == '{')
        {
            depth++;
            i++;
        }
        else if (c == '}')
        {
            depth--;
            i++;
            if (depth == 0)
                return cast(ptrdiff_t) i;
        }
        else
        {
            i++;
        }
    }
    return -1;
}

/**
 * Splits `src` into logical lines and tokenises each.
 *
 * Throws `KilnError` `E_PARSE <file>:<line>` for the earliest lexical error.
 */
LogicalLine[] lexFile(string src, string file) @safe pure
{
    LogicalLine[] result;
    int physNo = 0;
    int groupStart = 0;
    long depth = 0;
    char[] group;
    bool inGroup = false;

    size_t pos = 0;
    while (pos < src.length)
    {
        size_t eol = pos;
        while (eol < src.length && src[eol] != '\n')
            eol++;
        auto line = src[pos .. eol];
        pos = eol + 1;
        physNo++;
        if (!inGroup)
        {
            groupStart = physNo;
            group.length = 0;
            depth = 0;
            inGroup = true;
        }

        // Stages 1 and 2 in one pass over the physical line.
        size_t cut = line.length;
        size_t i = 0;
        while (i < line.length)
        {
            immutable c = line[i];
            if (c == '"' || c == '\'')
            {
                immutable e = skipLiteral(line, i);
                if (e < 0)
                    failParse(file, groupStart);
                i = cast(size_t) e;
            }
            else if (c == '#')
            {
                cut = i;
                break;
            }
            else
            {
                if (c == '(' || c == '[')
                    depth++;
                else if (c == ')' || c == ']')
                {
                    depth--;
                    if (depth < 0)
                        failParse(file, groupStart);
                }
                i++;
            }
        }
        while (cut > 0 && (line[cut - 1] == ' ' || line[cut - 1] == '\t'))
            cut--;
        if (physNo != groupStart)
            group ~= ' ';
        group ~= line[0 .. cut];

        if (depth == 0)
        {
            emit(result, group, groupStart, file);
            inGroup = false;
        }
    }
    if (inGroup)
        failParse(file, groupStart); // bracket still open at end of file
    return result;
}

private void emit(ref LogicalLine[] result, const(char)[] text, int number, string file) @safe pure
{
    bool blank = true;
    foreach (c; text)
        if (c != ' ' && c != '\t')
        {
            blank = false;
            break;
        }
    if (blank)
        return;
    LogicalLine ll;
    ll.number = number;
    try
        ll.tokens = tokenize(text.idup);
    catch (SyntaxFailure)
        failParse(file, number);
    result ~= ll;
}

/**
 * Stage 3: splits `text` into tokens. Throws $(LREF SyntaxFailure) on a byte
 * that cannot begin a token (including a bare `|` or `&`) and on an
 * unterminated literal.
 */
Token[] tokenize(string text) @safe pure
{
    Token[] toks;
    size_t i = 0;
    while (i < text.length)
    {
        immutable c = text[i];
        if (c == ' ' || c == '\t')
        {
            i++;
        }
        else if (isIdentStart(c))
        {
            size_t j = i + 1;
            while (j < text.length && isIdentChar(text[j]))
                j++;
            toks ~= Token(TokenKind.identifier, text[i .. j]);
            i = j;
        }
        else if (c >= '0' && c <= '9')
        {
            size_t j = i;
            ulong v = 0;
            while (j < text.length && text[j] >= '0' && text[j] <= '9')
            {
                v = v * 10 + (text[j] - '0');
                j++;
            }
            Token t;
            t.kind = TokenKind.integer;
            t.text = text[i .. j];
            t.intValue = cast(long) v;
            toks ~= t;
            i = j;
        }
        else if (c == '"' || c == '\'')
        {
            immutable e = skipLiteral(text, i);
            if (e < 0)
                throw new SyntaxFailure;
            Token t;
            t.kind = TokenKind.str;
            t.text = text[i + 1 .. cast(size_t) e - 1];
            t.doubleQuoted = c == '"';
            toks ~= t;
            i = cast(size_t) e;
        }
        else
        {
            // Operators and punctuation, longest match first.
            string two = i + 1 < text.length ? text[i .. i + 2] : "";
            switch (two)
            {
            case "|>", "||", "&&", "==", "!=", "<=", ">=", "++":
                toks ~= Token(TokenKind.op, two);
                i += 2;
                continue;
            default:
                break;
            }
            switch (c)
            {
            case '(', ')', '[', ']', '{', '}', ',', '=':
                toks ~= Token(TokenKind.punct, text[i .. i + 1]);
                break;
            case '<', '>', '~', '+', '-', '*', '/', '%', '!':
                toks ~= Token(TokenKind.op, text[i .. i + 1]);
                break;
            default:
                throw new SyntaxFailure; // bare | or &, or any other byte
            }
            i++;
        }
    }
    return toks;
}

@safe pure unittest
{
    import kiln.errors : KilnError;
    import std.exception : assertThrown, collectException;

    auto lines = lexFile("let a = 1 # comment\n\nlet b = f(\n  1,\n  2)\n", "main.kiln");
    assert(lines.length == 2);
    assert(lines[0].number == 1 && lines[1].number == 3);
    assert(lines[1].tokens.length == 9);

    // A '#' inside a string literal is content, not a comment.
    lines = lexFile("let s = \"a#b\" # c\n", "f");
    assert(lines[0].tokens.length == 4 && lines[0].tokens[3].text == "a#b");

    // Errors are reported at the first physical line of the logical line.
    auto e = collectException!KilnError(lexFile("let b = f(\n  \"unterminated\n)\n", "f"));
    assert(e && e.detail == "f:1");
    e = collectException!KilnError(lexFile("x = (\n", "f"));
    assert(e && e.detail == "f:1");
    e = collectException!KilnError(lexFile("a\nlet x = 1 | 2\n", "f"));
    assert(e && e.detail == "f:2");
    e = collectException!KilnError(lexFile("let = 1\nlet x = \"abc\n", "f"));
    assert(e && e.detail == "f:2");

    // Interpolation regions may contain nested literals and braces.
    lines = lexFile("cmd write(\"{join(xs, \", \")}\\n\")\n", "f");
    assert(lines[0].tokens.length == 5);

    auto toks = tokenize("a |> b || c ++ d <= e");
    assert(toks.length == 9 && toks[1].text == "|>" && toks[3].text == "||");
}
