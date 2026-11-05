/**
 * KBL lexical analysis: comment stripping, logical-line assembly and
 * tokenisation, sharing one literal scanner so the stages cannot disagree.
 */
module kiln.lexer;

import kiln.errors;

/// Token kinds. Punctuation and operators are told apart by their text.
enum Tk : ubyte
{
    ident,
    integer,
    str,
    punct,
    op,
}

/// A token. For `str` tokens `text` is the raw text between the quotes.
struct Token
{
    Tk kind;
    /// True for a double-quoted string token.
    bool doubleQuoted;
    string text;

    bool isPunct(string p) const @safe pure nothrow @nogc
    {
        return kind == Tk.punct && text == p;
    }

    bool isOp(string p) const @safe pure nothrow @nogc
    {
        return kind == Tk.op && text == p;
    }

    bool isIdent(string p) const @safe pure nothrow @nogc
    {
        return kind == Tk.ident && text == p;
    }
}

/// A logical line: its first physical line number and its tokens.
struct LogicalLine
{
    int line;
    Token[] tokens;
}

/// The reserved words of KBL.
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

/**
 * Given `s[i]` is a quote, returns the index just past the closing quote of
 * the literal that starts there, or -1 if the text ends first.
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
            if (i + 1 >= s.length)
                return -1;
            i += 2;
        }
        else if (c == '{')
        {
            if (i + 1 < s.length && s[i + 1] == '{')
                i += 2;
            else
            {
                i++;
                int depth = 1;
                while (depth > 0)
                {
                    if (i >= s.length)
                        return -1;
                    immutable d = s[i];
                    if (d == '"' || d == '\'')
                    {
                        immutable j = skipLiteral(s, i);
                        if (j < 0)
                            return -1;
                        i = j;
                    }
                    else
                    {
                        if (d == '{')
                            depth++;
                        else if (d == '}')
                            depth--;
                        i++;
                    }
                }
            }
        }
        else if (c == '}')
        {
            i += (i + 1 < s.length && s[i + 1] == '}') ? 2 : 1;
        }
        else if (c == '"')
            return cast(ptrdiff_t)(i + 1);
        else
            i++;
    }
    return -1;
}

private bool isIdentStart(char c) @safe pure nothrow @nogc
{
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_';
}

private bool isDigit(char c) @safe pure nothrow @nogc
{
    return c >= '0' && c <= '9';
}

/**
 * Splits `text` into tokens. Returns false on a byte that cannot begin a
 * token (including a bare `|` or `&`) or an unterminated literal.
 */
bool tokenize(string text, out Token[] tokens) @safe pure nothrow
{
    Token[] r;
    size_t i = 0;
    while (i < text.length)
    {
        immutable c = text[i];
        if (c == ' ' || c == '\t')
        {
            i++;
            continue;
        }
        if (c == '"' || c == '\'')
        {
            immutable j = skipLiteral(text, i);
            if (j < 0)
                return false;
            r ~= Token(Tk.str, c == '"', text[i + 1 .. j - 1]);
            i = j;
        }
        else if (isIdentStart(c))
        {
            size_t j = i + 1;
            while (j < text.length && (isIdentStart(text[j]) || isDigit(text[j])))
                j++;
            r ~= Token(Tk.ident, false, text[i .. j]);
            i = j;
        }
        else if (isDigit(c))
        {
            size_t j = i + 1;
            while (j < text.length && isDigit(text[j]))
                j++;
            r ~= Token(Tk.integer, false, text[i .. j]);
            i = j;
        }
        else
        {
            if (i + 1 < text.length)
            {
                immutable two = text[i .. i + 2];
                if (two == "|>" || two == "||" || two == "&&" || two == "==" || two == "!="
                        || two == "<=" || two == ">=" || two == "++")
                {
                    r ~= Token(Tk.op, false, two);
                    i += 2;
                    continue;
                }
            }
            switch (c)
            {
            case '(', ')', '[', ']', '{', '}', ',', '=':
                r ~= Token(Tk.punct, false, text[i .. i + 1]);
                break;
            case '~', '+', '-', '*', '/', '%', '!', '<', '>':
                r ~= Token(Tk.op, false, text[i .. i + 1]);
                break;
            default:
                return false;
            }
            i++;
        }
    }
    tokens = r;
    return true;
}

private enum ScanStatus
{
    ok,
    unterminated,
    negativeDepth,
}

// Strips the comment from one physical line and updates the bracket depth.
private ScanStatus scanPhysical(string line, ref int depth, out string stripped) @safe pure nothrow
{
    size_t i = 0;
    size_t cut = line.length;
    while (i < line.length)
    {
        immutable c = line[i];
        if (c == '"' || c == '\'')
        {
            immutable j = skipLiteral(line, i);
            if (j < 0)
                return ScanStatus.unterminated;
            i = j;
            continue;
        }
        if (c == '#')
        {
            cut = i;
            break;
        }
        if (c == '(' || c == '[')
            depth++;
        else if (c == ')' || c == ']')
        {
            depth--;
            if (depth < 0)
                return ScanStatus.negativeDepth;
        }
        i++;
    }
    while (cut > 0 && (line[cut - 1] == ' ' || line[cut - 1] == '\t'))
        cut--;
    stripped = line[0 .. cut];
    return ScanStatus.ok;
}

/**
 * Lexes a whole build file into logical lines of tokens.
 *
 * Throws: `KilnError` (`E_PARSE <file>:<line>`) for the earliest logical line
 * with a lexical error.
 */
LogicalLine[] lexFile(string src, string file) @safe
{
    LogicalLine[] result;
    int lineNo = 0;
    int groupStart = 0;
    int depth = 0;
    string group;
    bool open = false;
    size_t pos = 0;
    while (pos < src.length)
    {
        size_t eol = pos;
        while (eol < src.length && src[eol] != '\n')
            eol++;
        string phys = src[pos .. eol];
        pos = eol + 1;
        lineNo++;
        if (!open)
        {
            groupStart = lineNo;
            group = null;
            depth = 0;
        }
        string stripped;
        immutable st = scanPhysical(phys, depth, stripped);
        if (st != ScanStatus.ok)
            throw parseError(file, groupStart);
        group = open ? group ~ " " ~ stripped : stripped;
        if (depth == 0)
        {
            open = false;
            bool blank = true;
            foreach (c; group)
                if (c != ' ' && c != '\t')
                {
                    blank = false;
                    break;
                }
            if (!blank)
            {
                Token[] toks;
                if (!tokenize(group, toks))
                    throw parseError(file, groupStart);
                result ~= LogicalLine(groupStart, toks);
            }
        }
        else
            open = true;
    }
    if (open)
        throw parseError(file, groupStart);
    return result;
}
