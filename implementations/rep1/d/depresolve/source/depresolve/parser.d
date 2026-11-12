/**
 * Parser for the registry/root text format.
 *
 * ---
 * a 1.0.0: c ^1.0.0
 * b 1.0.0: c ~1.2.0, d >=1.0.0 <3.0.0
 * c 1.2.5:
 * root: a *, b *
 * ---
 *
 * Every line ends in `\n`; the last line is the `root:` manifest.
 */
module depresolve.parser;

import depresolve.registry;
import depresolve.semver;

/// The result of parsing: a registry and the root manifest's requirements.
struct Problem
{
    Registry registry;     /// All package versions.
    Dependency[] root;     /// Requirements of the root manifest, in order.
}

/// Parses a complete input text. Throws `SyntaxException` if malformed.
Problem parseProblem(string text) @safe
{
    Problem p;
    bool sawRoot = false;
    size_t pos = 0;
    while (pos < text.length)
    {
        if (sawRoot)
            throw new SyntaxException("content after the root line");
        size_t eol = pos;
        while (eol < text.length && text[eol] != '\n') ++eol;
        if (eol == text.length)
            throw new SyntaxException("missing newline at end of input");
        auto line = text[pos .. eol];
        pos = eol + 1;

        if (line.length >= 5 && line[0 .. 5] == "root:")
        {
            p.root = parseRequirements(line[5 .. $]);
            sawRoot = true;
        }
        else
        {
            size_t sp = 0;
            while (sp < line.length && line[sp] != ' ') ++sp;
            if (sp == 0 || sp == line.length)
                throw new SyntaxException("malformed registry line: " ~ line);
            auto name = line[0 .. sp];
            checkName(name);
            size_t q = sp + 1;
            auto v = Version.parsePrefix(line, q);
            if (q >= line.length || line[q] != ':')
                throw new SyntaxException("expected ':' in: " ~ line);
            p.registry.add(name, v, parseRequirements(line[q + 1 .. $]));
        }
    }
    if (!sawRoot)
        throw new SyntaxException("missing root line");
    return p;
}

/**
 * Parses the text after the colon of a line: either empty, or a space
 * followed by `name range` items separated by `", "`.
 */
Dependency[] parseRequirements(string s) @safe
{
    if (s.length == 0)
        return null;
    if (s[0] != ' ')
        throw new SyntaxException("expected space after ':'");
    s = s[1 .. $];

    Dependency[] deps;
    for (;;)
    {
        // Find the end of this requirement: next ", " or end of string.
        size_t end = 0;
        while (end < s.length && !(s[end] == ',' && end + 1 < s.length && s[end + 1] == ' '))
            ++end;
        auto item = s[0 .. end];
        size_t sp = 0;
        while (sp < item.length && item[sp] != ' ') ++sp;
        if (sp == 0 || sp == item.length)
            throw new SyntaxException("malformed requirement: " ~ item);
        auto name = item[0 .. sp];
        checkName(name);
        deps ~= Dependency(name, VersionRange.parse(item[sp + 1 .. $]));
        if (end == s.length)
            break;
        s = s[end + 2 .. $];
    }
    return deps;
}

private void checkName(string name) @safe
{
    if (name.length == 0 || !(name[0] >= 'a' && name[0] <= 'z'))
        throw new SyntaxException("invalid package name: " ~ name);
    foreach (c; name)
        if (!((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-'))
            throw new SyntaxException("invalid package name: " ~ name);
}

@safe unittest
{
    auto p = parseProblem("root:\n");
    assert(p.registry.entries.length == 0);
    assert(p.root.length == 0);
}

@safe unittest
{
    auto p = parseProblem(
        "a 1.0.0: c ^1.0.0\n" ~
        "b 1.0.0: c ~1.2.0, d >=1.0.0 <3.0.0\n" ~
        "c 1.2.5:\n" ~
        "root: a *, b 1.0.0\n");
    assert(p.registry.entries.length == 3);
    assert(p.registry.entries[1].name == "b");
    assert(p.registry.entries[1].version_ == Version(1, 0, 0));
    assert(p.registry.entries[1].dependencies.length == 2);
    assert(p.registry.entries[1].dependencies[1].name == "d");
    assert(p.registry.entries[1].dependencies[1].range.contains(Version(2, 9, 9)));
    assert(!p.registry.entries[1].dependencies[1].range.contains(Version(3, 0, 0)));
    assert(p.root.length == 2);
    assert(p.root[1].range.contains(Version(1, 0, 0)));
    assert(!p.root[1].range.contains(Version(1, 0, 1)));
}

@safe unittest
{
    import std.exception : assertThrown;
    foreach (bad; ["", "a 1.0.0:\n", "root:", "root: a\n", "root: a *,b *\n", "root:a *\n",
                   "A 1.0.0:\nroot:\n", "a 1.0:\nroot:\n", "a 1.0.0\nroot:\n",
                   "root:\nextra 1.0.0:\n"])
        assertThrown!SyntaxException(parseProblem(bad), bad);
}
