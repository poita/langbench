/**
 * The KBL lexer: comment stripping, logical-line assembly and tokenisation.
 *
 * Comment stripping and bracket counting share one *literal scanner*
 * (`skipDouble` / `skipSingle` / `skipRegion`) so that every stage agrees on
 * what lies inside a string literal.
 */
module kiln.lexer;

import kiln.errors : SyntaxError;

/// A lexical token.
struct Token
{
    /// Token classes.  Punctuation and operators are both `symbol`.
    enum Kind : ubyte { ident, integer, str, symbol }

    ///
    Kind kind;
    /// The source text (for `str`, the whole literal including quotes).
    string text;

    /// True for the symbol with spelling `s`.
    bool isSym(string s) const @safe pure nothrow @nogc { return kind == Kind.symbol && text == s; }
    /// True for the identifier (or keyword) with spelling `s`.
    bool isIdent(string s) const @safe pure nothrow @nogc { return kind == Kind.ident && text == s; }
}

/// One logical line: its first physical line number and its tokens.
struct LogicalLine
{
    ///
    int line;
    ///
    Token[] tokens;
}

/// The reserved words of KBL.
immutable string[] reservedWords = [
    "abort", "after", "cmd", "cost", "default", "depfile", "each", "elsewhen", "false", "in",
    "include", "let", "otherwise", "out", "phony", "rule", "set", "step", "true", "use", "when",
];

/// True if `s` is a reserved word.
bool isReserved(const(char)[] s) @safe pure nothrow @nogc
{
    foreach (w; reservedWords)
        if (w == s)
            return true;
    return false;
}

/// Skips a single-quoted literal starting at `s[i] == '\''`; returns the index after the closing quote.
size_t skipSingle(const(char)[] s, size_t i) @safe pure
{
    size_t j = i + 1;
    while (true)
    {
        if (j >= s.length)
            throw new SyntaxError(0, "unterminated literal");
        if (s[j] == '\'')
        {
            if (j + 1 < s.length && s[j + 1] == '\'')
                j += 2;
            else
                return j + 1;
        }
        else
            ++j;
    }
}

/// Skips a double-quoted literal starting at `s[i] == '"'`; returns the index after the closing quote.
size_t skipDouble(const(char)[] s, size_t i) @safe pure
{
    size_t j = i + 1;
    while (true)
    {
        if (j >= s.length)
            throw new SyntaxError(0, "unterminated literal");
        const c = s[j];
        if (c == '\\')
            j += 2;
        else if (c == '"')
            return j + 1;
        else if (c == '{')
        {
            if (j + 1 < s.length && s[j + 1] == '{')
                j += 2;
            else
                j = skipRegion(s, j + 1);
        }
        else if (c == '}')
            j += (j + 1 < s.length && s[j + 1] == '}') ? 2 : 1;
        else
            ++j;
    }
}

/// Skips an interpolation region whose body starts at `s[i]`; returns the index after the closing `}`.
size_t skipRegion(const(char)[] s, size_t i) @safe pure
{
    size_t j = i;
    int depth = 1;
    while (true)
    {
        if (j >= s.length)
            throw new SyntaxError(0, "unterminated interpolation");
        const c = s[j];
        if (c == '"')
            j = skipDouble(s, j);
        else if (c == '\'')
            j = skipSingle(s, j);
        else
        {
            ++j;
            if (c == '{')
                ++depth;
            else if (c == '}' && --depth == 0)
                return j;
        }
    }
}

private bool isIdentStart(char c) @safe pure nothrow @nogc
{
    return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || c == '_';
}

private bool isDigit(char c) @safe pure nothrow @nogc
{
    return c >= '0' && c <= '9';
}

/// Splits `text` (one logical line, or an interpolation body) into tokens.
Token[] tokenize(string text) @safe pure
{
    Token[] tokens;
    size_t i = 0;
    while (i < text.length)
    {
        const c = text[i];
        if (c == ' ' || c == '\t')
        {
            ++i;
        }
        else if (isIdentStart(c))
        {
            size_t j = i + 1;
            while (j < text.length && (isIdentStart(text[j]) || isDigit(text[j])))
                ++j;
            tokens ~= Token(Token.Kind.ident, text[i .. j]);
            i = j;
        }
        else if (isDigit(c))
        {
            size_t j = i + 1;
            while (j < text.length && isDigit(text[j]))
                ++j;
            tokens ~= Token(Token.Kind.integer, text[i .. j]);
            i = j;
        }
        else if (c == '"' || c == '\'')
        {
            const j = c == '"' ? skipDouble(text, i) : skipSingle(text, i);
            tokens ~= Token(Token.Kind.str, text[i .. j]);
            i = j;
        }
        else
        {
            if (i + 1 < text.length)
            {
                const two = text[i .. i + 2];
                switch (two)
                {
                case "|>": case "||": case "&&": case "==": case "!=": case "<=": case ">=": case "++":
                    tokens ~= Token(Token.Kind.symbol, two);
                    i += 2;
                    continue;
                default:
                    break;
                }
            }
            switch (c)
            {
            case '(': case ')': case '[': case ']': case '{': case '}': case ',': case '=':
            case '<': case '>': case '~': case '+': case '-': case '*': case '/': case '%': case '!':
                tokens ~= Token(Token.Kind.symbol, text[i .. i + 1]);
                ++i;
                break;
            default:
                throw new SyntaxError(0, "bad byte");
            }
        }
    }
    return tokens;
}

private bool isBlank(const(char)[] s) @safe pure nothrow @nogc
{
    foreach (char c; s)
        if (c != ' ' && c != '\t')
            return false;
    return true;
}

/**
 * Runs stages 1-3 over a whole build file.
 *
 * Throws: `SyntaxError` carrying the first physical line of the logical line
 * that holds the earliest lexical error.
 */
LogicalLine[] lexSource(string source) @safe pure
{
    LogicalLine[] result;
    int groupStart = 0;
    int depth = 0;
    string group;
    bool inGroup = false;

    int lineNo = 0;
    size_t pos = 0;
    while (pos <= source.length)
    {
        // Next physical line.
        size_t end = pos;
        while (end < source.length && source[end] != '\n')
            ++end;
        const physical = source[pos .. end];
        pos = end + 1;
        ++lineNo;
        if (!inGroup)
        {
            groupStart = lineNo;
            group = "";
            depth = 0;
            inGroup = true;
        }
        try
        {
            size_t i = 0;
            size_t cut = physical.length;
            while (i < physical.length)
            {
                const c = physical[i];
                if (c == '"')
                    i = skipDouble(physical, i);
                else if (c == '\'')
                    i = skipSingle(physical, i);
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
                        if (--depth < 0)
                            throw new SyntaxError(0, "unbalanced bracket");
                    }
                    ++i;
                }
            }
            while (cut > 0 && (physical[cut - 1] == ' ' || physical[cut - 1] == '\t'))
                --cut;
            group = lineNo == groupStart ? physical[0 .. cut] : group ~ " " ~ physical[0 .. cut];
            if (depth == 0)
            {
                inGroup = false;
                if (!isBlank(group))
                    result ~= LogicalLine(groupStart, tokenize(group));
            }
        }
        catch (SyntaxError e)
        {
            e.line = groupStart;
            throw e;
        }
    }
    if (inGroup && depth > 0)
        throw new SyntaxError(groupStart, "unclosed bracket");
    return result;
}

version (unittest)
{
    private string[] texts(LogicalLine l)
    {
        string[] r;
        foreach (t; l.tokens)
            r ~= t.text;
        return r;
    }
}

unittest
{
    auto lines = lexSource("let x = 1 # comment\n\n  # only comment\nlet y = f(\n  1,\n  2)\n");
    assert(lines.length == 2);
    assert(lines[0].line == 1 && texts(lines[0]) == ["let", "x", "=", "1"]);
    assert(lines[1].line == 4 && texts(lines[1]) == ["let", "y", "=", "f", "(", "1", ",", "2", ")"]);
}

unittest
{
    // A '#' or bracket inside a literal is content; interpolation brackets do not count.
    auto lines = lexSource("cmd write(\"{join(xs, \", \")}#(\\n\")\n");
    assert(lines.length == 1);
    assert(lines[0].tokens.length == 5 && lines[0].tokens[3].kind == Token.Kind.str);
    auto l2 = lexSource("let s = 'it''s # ('\n");
    assert(l2[0].tokens[3].text == "'it''s # ('");
}

unittest
{
    void expectErr(string src, int line)
    {
        try
        {
            lexSource(src);
            assert(false, "expected error for " ~ src);
        }
        catch (SyntaxError e)
            assert(e.line == line, src);
    }

    expectErr("let b = f(\n  \"unterminated\n)\n", 1);
    expectErr("a\nlet b = )\n", 2);
    expectErr("a\n(\n(\n", 2);
    expectErr("let x = 1 | 2\n", 1);
    expectErr("let x = 1 & 2\n", 1);
    expectErr("let x = $\n", 1);
    expectErr("let x = \"{a\n", 1);
}

unittest
{
    auto t = tokenize("a|>b||c&&d==e!=f<=g>=h<i>j++k~l+m-n*o/p%q!r");
    string[] syms;
    foreach (x; t)
        if (x.kind == Token.Kind.symbol)
            syms ~= x.text;
    assert(syms == ["|>", "||", "&&", "==", "!=", "<=", ">=", "<", ">", "++", "~", "+", "-", "*", "/", "%", "!"]);
    assert(isReserved("when") && !isReserved("weight"));
}
