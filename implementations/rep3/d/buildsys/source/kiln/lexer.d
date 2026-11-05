/// The KBL lexer: comment stripping, logical-line assembly and tokenisation.
module kiln.lexer;

import kiln.errors;

/// Token kinds.
enum TokKind : ubyte
{
    ident,
    integer,
    str,   /// a string literal; `text` holds the raw source including quotes
    sym,   /// punctuation or operator; `text` holds its spelling
}

/// A token.
struct Token
{
    TokKind kind;
    string text;

    bool isSym(string s) const @safe pure nothrow @nogc
    {
        return kind == TokKind.sym && text == s;
    }

    bool isIdent(string s) const @safe pure nothrow @nogc
    {
        return kind == TokKind.ident && text == s;
    }
}

/// A logical line: its 1-based first physical line number and its tokens.
struct LogicalLine
{
    int line;
    Token[] toks;
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

/// Skip the string literal whose opening quote is at `s[i]`; returns the index
/// just past its closing quote. Throws `SyntaxFail` when unterminated. This is
/// the single literal scanner shared by every lexing stage.
size_t skipLiteral(const(char)[] s, size_t i) @safe pure
{
    immutable n = s.length;
    immutable q = s[i];
    size_t j = i + 1;
    if (q == '\'')
    {
        while (true)
        {
            if (j >= n)
                throw new SyntaxFail("unterminated literal");
            if (s[j] == '\'')
            {
                if (j + 1 < n && s[j + 1] == '\'')
                {
                    j += 2;
                    continue;
                }
                return j + 1;
            }
            ++j;
        }
    }
    while (true)
    {
        if (j >= n)
            throw new SyntaxFail("unterminated literal");
        immutable c = s[j];
        if (c == '\\')
            j += 2;
        else if (c == '{')
        {
            if (j + 1 < n && s[j + 1] == '{')
            {
                j += 2;
                continue;
            }
            // interpolation region
            int depth = 1;
            ++j;
            while (depth > 0)
            {
                if (j >= n)
                    throw new SyntaxFail("unterminated interpolation");
                immutable d = s[j];
                if (d == '"' || d == '\'')
                    j = skipLiteral(s, j);
                else
                {
                    if (d == '{')
                        ++depth;
                    else if (d == '}')
                        --depth;
                    ++j;
                }
            }
        }
        else if (c == '}')
        {
            if (j + 1 < n && s[j + 1] == '}')
                j += 2;
            else
                ++j;
        }
        else if (c == '"')
            return j + 1;
        else
            ++j;
    }
}

/// Split `text` into tokens (stage 3). Throws `SyntaxFail` on a byte that
/// cannot begin a token or an unterminated literal.
Token[] tokenize(string text) @safe pure
{
    Token[] toks;
    size_t i = 0;
    immutable n = text.length;
    while (i < n)
    {
        immutable c = text[i];
        if (c == ' ' || c == '\t')
        {
            ++i;
            continue;
        }
        if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_')
        {
            size_t j = i + 1;
            while (j < n && ((text[j] >= 'a' && text[j] <= 'z') || (text[j] >= 'A' && text[j] <= 'Z')
                    || text[j] == '_' || (text[j] >= '0' && text[j] <= '9')))
                ++j;
            toks ~= Token(TokKind.ident, text[i .. j]);
            i = j;
        }
        else if (c >= '0' && c <= '9')
        {
            size_t j = i + 1;
            while (j < n && text[j] >= '0' && text[j] <= '9')
                ++j;
            toks ~= Token(TokKind.integer, text[i .. j]);
            i = j;
        }
        else if (c == '"' || c == '\'')
        {
            immutable j = skipLiteral(text, i);
            toks ~= Token(TokKind.str, text[i .. j]);
            i = j;
        }
        else
        {
            if (i + 1 < n)
            {
                auto two = text[i .. i + 2];
                if (two == "|>" || two == "||" || two == "&&" || two == "==" || two == "!="
                        || two == "<=" || two == ">=" || two == "++")
                {
                    toks ~= Token(TokKind.sym, two);
                    i += 2;
                    continue;
                }
            }
            switch (c)
            {
            case '(', ')', '[', ']', '{', '}', ',', '=', '<', '>', '~', '+', '-', '*', '/', '%', '!':
                toks ~= Token(TokKind.sym, text[i .. i + 1]);
                ++i;
                break;
            default:
                throw new SyntaxFail("bad byte");
            }
        }
    }
    return toks;
}

/// Lex a whole build file into logical lines (stages 1-3). Throws
/// `E_PARSE <file>:<line>` for the earliest lexical error.
LogicalLine[] lexFile(string src, string file)
{
    LogicalLine[] result;
    // physical lines
    size_t pos = 0;
    int lineNo = 0;
    string group;
    int groupStart = 0;
    int depth = 0;
    bool open = false;
    bool firstOfGroup = true;
    while (pos < src.length)
    {
        size_t eol = pos;
        while (eol < src.length && src[eol] != '\n')
            ++eol;
        auto phys = src[pos .. eol];
        pos = eol + 1;
        ++lineNo;
        if (!open)
        {
            groupStart = lineNo;
            group = null;
            depth = 0;
            open = true;
            firstOfGroup = true;
        }
        // stages 1 and 2 in one pass
        size_t i = 0;
        size_t cut = phys.length;
        try
        {
            while (i < phys.length)
            {
                immutable c = phys[i];
                if (c == '"' || c == '\'')
                    i = skipLiteral(phys, i);
                else if (c == '#')
                {
                    cut = i;
                    break;
                }
                else
                {
                    if (c == '(' || c == '[')
                        ++depth;
                    else if (c == ')' || c == ']')
                    {
                        --depth;
                        if (depth < 0)
                            throw new SyntaxFail("negative depth");
                    }
                    ++i;
                }
            }
        }
        catch (SyntaxFail)
            throw parseError(file, groupStart);
        auto text = phys[0 .. cut];
        while (text.length > 0 && (text[$ - 1] == ' ' || text[$ - 1] == '\t'))
            text = text[0 .. $ - 1];
        group = firstOfGroup ? text : group ~ " " ~ text;
        firstOfGroup = false;
        if (depth == 0)
        {
            open = false;
            finishLine(result, group, groupStart, file);
        }
    }
    if (open)
        throw parseError(file, groupStart);
    return result;
}

private void finishLine(ref LogicalLine[] result, string text, int line, string file)
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
    try
        result ~= LogicalLine(line, tokenize(text));
    catch (SyntaxFail)
        throw parseError(file, line);
}
