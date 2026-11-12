/// The complete stdin → stdout contract of the command-line tool, as a
/// library function so that it can be tested without spawning a process.
module myersdiff.protocol;

import std.conv : to;
import std.range.primitives : put, isOutputRange;
import myersdiff.intern : Line;
import myersdiff.myers : diffLines;
import myersdiff.parse;
import myersdiff.patch : applyScript;
import myersdiff.script : parseScript, writeScript;

/**
 * Handles one request and writes the response to `sink`.
 *
 * Params:
 *   input = the whole request text (see `myersdiff.parse`)
 *   sink  = an output range accepting `const(char)[]`
 *
 * Throws: `ParseException`, `ScriptException` or `PatchException` for
 * invalid input; nothing has been written to `sink` in that case.
 */
void process(Sink)(Line input, ref Sink sink)
if (isOutputRange!(Sink, const(char)[]))
{
    auto req = parseRequest(input);
    final switch (req.mode)
    {
    case Mode.diff:
        writeScript(sink, diffLines(req.first, req.second), req.first, req.second);
        break;
    case Mode.patch:
        auto b = applyScript(req.first, parseScript(req.second));
        put(sink, to!string(b.length));
        put(sink, "\n");
        foreach (l; b)
        {
            put(sink, l);
            put(sink, "\n");
        }
        break;
    }
}

/// Convenience wrapper returning the response as a string.
string process(Line input)
{
    import std.array : appender;
    auto sink = appender!string;
    process(input, sink);
    return sink.data;
}

unittest // patch example from the specification
{
    assert(process("patch\n5\na\nb\nc\nd\ne\n8\n a\n-b\n+B\n c\n+c2\n-d\n e\n+f\n")
           == "6\na\nB\nc\nc2\ne\nf\n");
}

unittest // diff of identical / empty files
{
    assert(process("diff\n0\n0\n") == "0\n");
    assert(process("diff\n2\nx\ny\n2\nx\ny\n") == "2\n x\n y\n");
    assert(process("patch\n0\n0\n") == "0\n");
}

unittest // whitespace is significant
{
    assert(process("diff\n1\na \n1\na\n") == "2\n-a \n+a\n");
}

unittest // tag look-alike lines
{
    // Keep lines carry the tag " " before the text "-" / "+".
    assert(process("diff\n2\n-\n+\n2\n-\n+\n") == "2\n -\n +\n");
    // Deleting the line "+" and inserting the line "-".
    assert(process("diff\n1\n+\n1\n-\n") == "2\n-+\n+-\n");
}
