/// KBL lexical analysis: comment stripping, logical-line assembly, tokenisation.
module kiln.lexer;

import kiln.errors;

/// Kind of a lexical token.
enum TokKind : ubyte
{
    ident,
    integer,
    str,
    sym
}

/// A lexical token.
struct Token
{
    TokKind kind;
    string text; /// identifier name, symbol spelling, or the raw body of a string literal
    long value; /// value of an integer token
    bool dq; /// for strings: double-quoted (interpolating) rather than single-quoted
}

/// A logical line: its first physical line number, its text and its tokens.
struct LogicalLine
{
    int line;
    string text;
    Token[] tokens;
}

/// The reserved words, which cannot be used as names.
bool isReserved(const(char)[] s) pure nothrow @safe
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

/// The literal scanner shared by all lexing stages.
///
/// `i` is the index just after the opening quote `q`. Returns the index just
/// after the closing quote, or -1 if the literal is unterminated.
ptrdiff_t scanLiteral(const(char)[] s, size_t i, char q) pure nothrow @nogc @safe
{
    const n = s.length;
    if (q == '\'')
    {
        while (i < n)
        {
            if (s[i] == '\'')
            {
                if (i + 1 < n && s[i + 1] == '\'')
                {
                    i += 2;
                    continue;
                }
                return cast(ptrdiff_t)(i + 1);
            }
            ++i;
        }
        return -1;
    }
    while (i < n)
    {
        const c = s[i];
        if (c == '\\')
        {
            i += 2;
        }
        else if (c == '{')
        {
            if (i + 1 < n && s[i + 1] == '{')
            {
                i += 2;
                continue;
            }
            const end = scanRegion(s, i + 1);
            if (end < 0)
                return -1;
            i = cast(size_t) end;
        }
        else if (c == '}')
        {
            i += (i + 1 < n && s[i + 1] == '}') ? 2 : 1;
        }
        else if (c == '"')
        {
            return cast(ptrdiff_t)(i + 1);
        }
        else
            ++i;
    }
    return -1;
}

/// Scans an interpolation region starting just after its `{`. Returns the index
/// just after the matching `}`, or -1 if the region is not closed.
ptrdiff_t scanRegion(const(char)[] s, size_t i) pure nothrow @nogc @safe
{
    int depth = 1;
    const n = s.length;
    while (depth > 0)
    {
        if (i >= n)
            return -1;
        const c = s[i];
        if (c == '"' || c == '\'')
        {
            const j = scanLiteral(s, i + 1, c);
            if (j < 0)
                return -1;
            i = cast(size_t) j;
            continue;
        }
        if (c == '{')
            ++depth;
        else if (c == '}')
            --depth;
        ++i;
    }
    return cast(ptrdiff_t) i;
}

private bool isIdentStart(char c) pure nothrow @nogc @safe
{
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_';
}

private bool isDigit(char c) pure nothrow @nogc @safe
{
    return c >= '0' && c <= '9';
}

/// Splits `s` into tokens. Returns false on a lexical error (a stray byte, a bare
/// `|` or `&`, or an unterminated literal).
bool tokenize(string s, out Token[] result) pure @safe
{
    Token[] toks;
    size_t i = 0;
    const n = s.length;
    while (i < n)
    {
        const c = s[i];
        if (c == ' ' || c == '\t')
        {
            ++i;
        }
        else if (isIdentStart(c))
        {
            size_t j = i + 1;
            while (j < n && (isIdentStart(s[j]) || isDigit(s[j])))
                ++j;
            toks ~= Token(TokKind.ident, s[i .. j]);
            i = j;
        }
        else if (isDigit(c))
        {
            size_t j = i;
            long v = 0;
            while (j < n && isDigit(s[j]))
            {
                v = v * 10 + (s[j] - '0');
                ++j;
            }
            toks ~= Token(TokKind.integer, s[i .. j], v);
            i = j;
        }
        else if (c == '"' || c == '\'')
        {
            const j = scanLiteral(s, i + 1, c);
            if (j < 0)
                return false;
            toks ~= Token(TokKind.str, s[i + 1 .. cast(size_t) j - 1], 0, c == '"');
            i = cast(size_t) j;
        }
        else
        {
            string two = i + 1 < n ? s[i .. i + 2] : null;
            switch (two)
            {
            case "|>", "||", "&&", "==", "!=", "<=", ">=", "++":
                toks ~= Token(TokKind.sym, two);
                i += 2;
                continue;
            default:
                break;
            }
            switch (c)
            {
            case '(', ')', '[', ']', '{', '}', ',', '=', '<', '>', '~', '+', '-', '*', '/', '%', '!':
                toks ~= Token(TokKind.sym, s[i .. i + 1]);
                ++i;
                break;
            default:
                return false;
            }
        }
    }
    result = toks;
    return true;
}

/// Runs lexical stages 1-3 over a whole build file.
///
/// Throws `KilnError` (`E_PARSE`) for the lexical error of the earliest logical
/// line, if any.
LogicalLine[] lexSource(string file, string text) @safe
{
    LogicalLine[] result;
    int depth = 0;
    int groupLine = 0;
    string groupText;
    bool inGroup = false;

    size_t pos = 0;
    int lineNo = 0;
    while (pos < text.length)
    {
        size_t eol = pos;
        while (eol < text.length && text[eol] != '\n')
            ++eol;
        const phys = text[pos .. eol];
        pos = eol + 1;
        ++lineNo;

        if (!inGroup)
        {
            inGroup = true;
            groupLine = lineNo;
            groupText = null;
        }

        // stage 1 + 2: scan the physical line
        size_t i = 0;
        size_t cut = phys.length;
        while (i < phys.length)
        {
            const c = phys[i];
            if (c == '"' || c == '\'')
            {
                const j = scanLiteral(phys, i + 1, c);
                if (j < 0)
                    throw parseError(file, groupLine);
                i = cast(size_t) j;
                continue;
            }
            if (c == '#')
            {
                cut = i;
                break;
            }
            if (c == '(' || c == '[')
                ++depth;
            else if (c == ')' || c == ']')
            {
                --depth;
                if (depth < 0)
                    throw parseError(file, groupLine);
            }
            ++i;
        }
        size_t e = cut;
        while (e > 0 && (phys[e - 1] == ' ' || phys[e - 1] == '\t'))
            --e;
        groupText = lineNo == groupLine ? phys[0 .. e] : groupText ~ " " ~ phys[0 .. e];

        if (depth == 0)
        {
            inGroup = false;
            bool blank = true;
            foreach (ch; groupText)
                if (ch != ' ' && ch != '\t')
                {
                    blank = false;
                    break;
                }
            if (!blank)
            {
                Token[] toks;
                if (!tokenize(groupText, toks))
                    throw parseError(file, groupLine);
                result ~= LogicalLine(groupLine, groupText, toks);
            }
        }
    }
    if (inGroup)
        throw parseError(file, groupLine);
    return result;
}
