/// Splitting of the input into the modules of a program (SPEC.md section 2).
module langvm.source;

import langvm.diag;
import langvm.lexer : isIdentifier;

/// One module of the input stream: its name and the lines of its body.
struct SourceModule
{
    /// The module name from its `@module` header.
    string name;
    /// The body: the lines strictly after the header, without line terminators.
    const(dchar)[][] lines;
}

/// Decode UTF-8 text into scalar values (bytes that are not valid UTF-8 are
/// mapped one-to-one so that decoding never fails).
const(dchar)[] decodeUtf8(const(char)[] text) @trusted
{
    import std.utf : toUTF32, UTFException;

    try
        return toUTF32(text);
    catch (UTFException)
    {
        dchar[] r;
        r.reserve(text.length);
        foreach (c; cast(const(ubyte)[]) text)
            r ~= cast(dchar) c;
        return r;
    }
}

/// Split `text` into lines: a line ends at LF, and one CR directly before the
/// LF is dropped. The final line need not be terminated; empty input has none.
const(dchar)[][] splitLines(const(dchar)[] text) @safe pure nothrow
{
    const(dchar)[][] lines;
    size_t start = 0;
    foreach (i, c; text)
    {
        if (c == '\n')
        {
            size_t end = i;
            if (end > start && text[end - 1] == '\r')
                end--;
            lines ~= text[start .. end];
            start = i + 1;
        }
    }
    if (start < text.length)
        lines ~= text[start .. $];
    return lines;
}

/// If `line` is exactly `@module <name>` with a valid name, return the name.
private bool parseHeader(const(dchar)[] line, out string name) @safe
{
    import std.conv : to;

    enum prefix = "@module "d;
    if (line.length <= prefix.length || line[0 .. prefix.length] != prefix)
        return false;
    auto rest = line[prefix.length .. $];
    if (rest.length > 200)
        return false;
    foreach (c; rest)
        if (c >= 0x80)
            return false;
    auto n = rest.to!string;
    if (!isIdentifier(n))
        return false;
    name = n;
    return true;
}

/// Split the whole input into modules, or throw `bad-module` / `dup-module`.
SourceModule[] splitModules(const(char)[] input) @safe
{
    auto lines = splitLines(decodeUtf8(input));
    if (lines.length == 0)
        throw err(Kind.badModule, Pos(1, 1));

    string[] names;
    size_t[] headerLine; // 0-based index of each header line
    foreach (i, ln; lines)
    {
        string name;
        const isHeader = parseHeader(ln, name);
        if (isHeader)
        {
            names ~= name;
            headerLine ~= i;
        }
        else if (i == 0 || (ln.length > 0 && ln[0] == '@'))
            throw err(Kind.badModule, Pos(cast(int) i + 1, 1));
    }
    foreach (i, n; names)
        foreach (j; 0 .. i)
            if (names[j] == n)
                throw err(Kind.dupModule, Pos(cast(int) headerLine[i] + 1, 1));

    SourceModule[] mods;
    foreach (k, n; names)
    {
        const from = headerLine[k] + 1;
        const to = k + 1 < names.length ? headerLine[k + 1] : lines.length;
        mods ~= SourceModule(n, lines[from .. to]);
    }
    return mods;
}

@safe unittest
{
    auto m = splitModules("@module a\nfn x\n@module b\r\n");
    assert(m.length == 2);
    assert(m[0].name == "a" && m[0].lines.length == 1);
    assert(m[1].name == "b" && m[1].lines.length == 0);
}

@safe unittest
{
    void expect(string input, Kind k, int line)
    {
        try
        {
            splitModules(input);
            assert(false, "expected an error");
        }
        catch (CompileError e)
        {
            assert(e.kind == k && e.pos.line == line && e.pos.col == 1);
        }
    }

    expect("", Kind.badModule, 1);
    expect("hello\n@module a\n", Kind.badModule, 1);
    expect("@module a\n@module  b\n", Kind.badModule, 2);
    expect("@module a\n@module a\n", Kind.dupModule, 2);
    expect("@module a \n", Kind.badModule, 1);
    expect("@module fn\n", Kind.badModule, 1);
}
