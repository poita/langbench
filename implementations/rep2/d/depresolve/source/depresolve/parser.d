/**
 * Parser for the textual registry format.
 *
 * ---
 * a 1.0.0: c ^1.0.0
 * c 1.2.5:
 * root: a *
 * ---
 *
 * Zero or more registry lines followed by exactly one root line.
 */
module depresolve.parser;

import std.string : indexOf;

import depresolve.range;
import depresolve.registry;
import depresolve.semver;

/**
 * Parse a whole input text (registry lines and the final root line) into a
 * `Registry`. Package names in the result are slices of `text`, not copies.
 *
 * Throws: `ParseException` if the text is malformed or has no root line.
 */
Registry parseInput(string text) pure @safe
{
    RegistryBuilder builder;
    bool sawRoot = false;
    size_t pos = 0;
    while (pos < text.length)
    {
        if (sawRoot)
            throw new ParseException("root line must be the last line");
        auto eol = text[pos .. $].indexOf('\n');
        immutable end = eol < 0 ? text.length : pos + eol;
        auto line = text[pos .. end];
        pos = end + 1;

        immutable colon = line.indexOf(':');
        if (colon < 0)
            throw new ParseException("missing ':' in line '" ~ line ~ "'");
        auto head = line[0 .. colon];
        auto reqs = parseRequirements(line[colon + 1 .. $]);
        if (head == "root")
        {
            builder.setRoot(reqs);
            sawRoot = true;
        }
        else
        {
            immutable sp = head.indexOf(' ');
            if (sp <= 0)
                throw new ParseException("malformed package version: '" ~ head ~ "'");
            builder.addVersion(head[0 .. sp], parseVersion(head[sp + 1 .. $]), reqs);
        }
    }
    if (!sawRoot)
        throw new ParseException("missing root line");
    return builder.build();
}

/**
 * Parse the text after the colon of a line: either empty, or a space followed
 * by `name range` items separated by `", "`.
 */
RequirementSpec[] parseRequirements(string text) pure @safe
{
    RequirementSpec[] into;
    if (text.length == 0)
        return into;
    if (text[0] != ' ')
        throw new ParseException("expected ' ' after ':'");
    text = text[1 .. $];
    while (true)
    {
        immutable comma = text.indexOf(',');
        auto item = comma < 0 ? text : text[0 .. comma];
        immutable sp = item.indexOf(' ');
        if (sp <= 0)
            throw new ParseException("malformed requirement: '" ~ item ~ "'");
        into ~= RequirementSpec(item[0 .. sp], parseRange(item[sp + 1 .. $]));
        if (comma < 0)
            return into;
        if (comma + 1 >= text.length || text[comma + 1] != ' ')
            throw new ParseException("expected ', ' between requirements");
        text = text[comma + 2 .. $];
    }
}
