/// Splitting of the input into modules (the "module stream" of the language specification).
module langvm.source;

import langvm.diag;
import std.utf : toUTF32;

/// One module of the stream: its name and the lines of its body.
struct SourceModule
{
    /// The module name from its `@module` header.
    string name;
    /// The lines of the body (without line terminators), as arrays of Unicode scalar values.
    dstring[] lines;
}

/// Keywords of the language (never identifiers).
immutable string[] keywords = [
    "as", "break", "continue", "else", "enum", "false", "fn", "for", "if", "impl",
    "in", "let", "match", "pub", "return", "self", "struct", "trait", "true", "use",
    "var", "when", "while",
];

/// True if `s` is a keyword.
bool isKeyword(const(char)[] s)
{
    foreach (k; keywords)
        if (k == s)
            return true;
    return false;
}

/// True if `s` is a well-formed identifier of at most 200 characters, not a keyword and not `_`.
bool isIdentifier(const(char)[] s)
{
    if (s.length == 0 || s.length > 200)
        return false;
    foreach (i, c; s)
    {
        bool letter = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_';
        bool digit = c >= '0' && c <= '9';
        if (!(letter || (i > 0 && digit)))
            return false;
    }
    return s != "_" && !isKeyword(s);
}

/// Splits `input` (UTF-8) into lines: LF-terminated, a single CR before the LF removed.
string[] splitLines(string input)
{
    string[] lines;
    size_t start = 0;
    foreach (i, c; input)
    {
        if (c == '\n')
        {
            size_t end = i;
            if (end > start && input[end - 1] == '\r')
                end--;
            lines ~= input[start .. end];
            start = i + 1;
        }
    }
    if (start < input.length)
        lines ~= input[start .. $];
    return lines;
}

/// Splits the whole input into modules.
/// Throws: [CompileError] (`bad-module` or `dup-module`).
SourceModule[] splitModules(string input)
{
    auto lines = splitLines(input);
    if (lines.length == 0)
        throw new CompileError("bad-module", 1, 1);
    SourceModule[] mods;
    bool[string] seen;
    int dupLine = 0;
    foreach (idx, ln; lines)
    {
        int lineNo = cast(int) idx + 1;
        bool isHeader = false;
        string name;
        if (ln.length >= 8 && ln[0 .. 8] == "@module ")
        {
            name = ln[8 .. $];
            isHeader = isIdentifier(name);
        }
        if (isHeader)
        {
            if (name in seen)
            {
                if (dupLine == 0)
                    dupLine = lineNo;
            }
            seen[name] = true;
            SourceModule m;
            m.name = name;
            mods ~= m;
        }
        else if (idx == 0 || (ln.length > 0 && ln[0] == '@'))
            throw new CompileError("bad-module", lineNo, 1);
        else
            mods[$ - 1].lines ~= toUTF32(ln);
    }
    if (dupLine != 0)
        throw new CompileError("dup-module", dupLine, 1);
    return mods;
}
