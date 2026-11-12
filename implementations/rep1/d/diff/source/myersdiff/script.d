/**
 * The textual edit-script format.
 *
 * A script is a count line followed by that many script lines. Each script
 * line is one tag character (`' '` keep, `'-'` delete, `'+'` insert)
 * immediately followed by the line's content, which may be empty.
 */
module myersdiff.script;

import std.conv : to;
import std.range.primitives : put, isOutputRange;
import myersdiff.edit;
import myersdiff.intern : Line;

/// One parsed script line: its operation and the line text.
struct ScriptLine
{
    EditKind kind;
    Line text;
}

/// Thrown for a script line that does not start with a valid tag.
class ScriptException : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) @safe pure nothrow
    {
        super(msg, file, line);
    }
}

/// Parses one script line (tag + content).
ScriptLine parseScriptLine(Line line) @safe pure
{
    if (line.length == 0)
        throw new ScriptException("empty script line");
    switch (line[0])
    {
    case ' ': return ScriptLine(EditKind.keep, line[1 .. $]);
    case '-': return ScriptLine(EditKind.remove, line[1 .. $]);
    case '+': return ScriptLine(EditKind.insert, line[1 .. $]);
    default:  throw new ScriptException("invalid script tag");
    }
}

/// Parses all script lines (the count line is not part of `lines`).
ScriptLine[] parseScript(scope const(Line)[] lines) @safe pure
{
    auto r = new ScriptLine[lines.length];
    foreach (i, l; lines)
        r[i] = parseScriptLine(l);
    return r;
}

/**
 * Writes the script `edits` (as produced by `diffLines`) for files `a` and
 * `b` to the output range `sink`: the count line, then one line per edit.
 */
void writeScript(Sink)(ref Sink sink, scope const Edit[] edits,
                       scope const(Line)[] a, scope const(Line)[] b)
if (isOutputRange!(Sink, const(char)[]))
{
    put(sink, to!string(edits.length));
    put(sink, "\n");
    foreach (e; edits)
    {
        final switch (e.kind)
        {
        case EditKind.keep:
            put(sink, " ");
            put(sink, a[e.index]);
            break;
        case EditKind.remove:
            put(sink, "-");
            put(sink, a[e.index]);
            break;
        case EditKind.insert:
            put(sink, "+");
            put(sink, b[e.index]);
            break;
        }
        put(sink, "\n");
    }
}

///
unittest
{
    import std.array : appender;
    import myersdiff.myers : diffLines;

    const(char)[][] a = ["x", "y"], b = ["y", "z"];
    auto sink = appender!string;
    writeScript(sink, diffLines(a, b), a, b);
    assert(sink.data == "3\n-x\n y\n+z\n");
}

unittest
{
    auto s = parseScript(["+", " ", "-x", "+-x", "  "]);
    assert(s[0] == ScriptLine(EditKind.insert, ""));
    assert(s[1] == ScriptLine(EditKind.keep, ""));
    assert(s[2] == ScriptLine(EditKind.remove, "x"));
    assert(s[3] == ScriptLine(EditKind.insert, "-x"));
    assert(s[4] == ScriptLine(EditKind.keep, " "));
    import std.exception : assertThrown;
    assertThrown!ScriptException(parseScript(["?x"]));
    assertThrown!ScriptException(parseScript([""]));
}
