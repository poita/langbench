/**
 * Parser for the textual input format: registry lines followed by a root
 * line.
 *
 * ---
 * a 1.0.0: b ^1.0.0
 * b 1.2.0:
 * root: a *
 * ---
 */
module depresolve.parser;

import std.conv : to;

import depresolve.range;
import depresolve.registry;
import depresolve.semver;

/// A parsed input: the registry and the root manifest's requirements.
struct Problem
{
    /// All declared package versions (not yet sealed).
    Registry registry;
    /// Root requirements, in the order listed. Bound once the registry is sealed
    /// by the resolver; see `depresolve.resolver.resolve`.
    Requirement[] root;
}

/**
 * Parses a complete input text.
 *
 * Every line must end with `\n`; the last line must be the root line.
 *
 * Throws: `ParseException` when the text is malformed.
 */
Problem parseProblem(const(char)[] text) pure @safe
{
    Problem prob;
    size_t pos = 0;
    bool haveRoot = false;

    while (pos < text.length)
    {
        if (haveRoot)
            throw new ParseException("data after the root line");

        if (text.length - pos >= 5 && text[pos .. pos + 5] == "root:")
        {
            pos += 5;
            prob.root = parseRequirements(prob.registry, text, pos);
            haveRoot = true;
        }
        else
        {
            const nameStart = pos;
            while (pos < text.length && text[pos] != ' ' && text[pos] != '\n')
                ++pos;
            if (pos >= text.length || text[pos] != ' ' || pos == nameStart)
                throw new ParseException("malformed registry line at offset " ~ nameStart.to!string);
            const name = text[nameStart .. pos].idup;
            ++pos;
            const ver = parseVersionAt(text, pos);
            expect(text, pos, ':');
            const reqs = parseRequirements(prob.registry, text, pos);
            prob.registry.add(name, ver, reqs);
        }
        expect(text, pos, '\n');
    }
    if (!haveRoot)
        throw new ParseException("missing root line");
    return prob;
}

/// Parses `""` or `" name range, name range"` up to (not including) the newline.
private Requirement[] parseRequirements(ref Registry reg, const(char)[] text, ref size_t pos)
    pure @safe
{
    Requirement[] reqs;
    if (pos < text.length && text[pos] == '\n')
        return reqs;
    expect(text, pos, ' ');
    while (true)
    {
        const nameStart = pos;
        while (pos < text.length && text[pos] != ' ' && text[pos] != '\n')
            ++pos;
        if (pos >= text.length || text[pos] != ' ' || pos == nameStart)
            throw new ParseException("malformed requirement at offset " ~ nameStart.to!string);
        const id = reg.intern(text[nameStart .. pos].idup);
        ++pos;
        reqs ~= Requirement(id, parseRangeAt(text, pos));
        if (pos < text.length && text[pos] == ',')
        {
            ++pos;
            expect(text, pos, ' ');
        }
        else
            break;
    }
    return reqs;
}

unittest
{
    auto p = parseProblem("a 1.0.0: b ^1.0.0, c *\nb 1.2.0:\nroot: a *\n");
    assert(p.registry.packages.length == 3);
    assert(p.root.length == 1);
    assert(p.registry.pool.length == 2);
    assert(p.registry.packages[p.root[0].pkg].name == "a");
}

unittest
{
    auto p = parseProblem("root:\n");
    assert(p.root.length == 0);
    assert(p.registry.packages.length == 0);
}

unittest
{
    import std.exception : assertThrown;
    assertThrown!ParseException(parseProblem(""));
    assertThrown!ParseException(parseProblem("a 1.0.0:\n"));
    assertThrown!ParseException(parseProblem("root:\na 1.0.0:\n"));
    assertThrown!ParseException(parseProblem("a 1.0.0 b *\nroot:\n"));
    assertThrown!ParseException(parseProblem("root: a *"));
}

unittest
{
    // A package whose name merely starts with "root" is an ordinary package.
    auto p = parseProblem("rootx 1.0.0:\nroot: rootx *\n");
    assert(p.registry.find("rootx") != none);
    assert(p.root.length == 1);
}
