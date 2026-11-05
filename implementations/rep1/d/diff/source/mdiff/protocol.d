/**
 * The line-oriented stdin/stdout protocol of the `mdiff` tool.
 *
 * Input: a mode line (`diff` or `patch`), a count `N` and `N` lines of file
 * A, then either a count `M` and `M` lines of file B (mode `diff`) or a count
 * `K` and `K` script lines (mode `patch`). Output: a count line and that many
 * lines (the script, or the patched file). See the README for details.
 */
module mdiff.protocol;

import std.array : Appender, appender;
import mdiff.diff;
import mdiff.errors;
import mdiff.lines;
import mdiff.patch;
import mdiff.script;

/// Processes one complete request and returns the complete response.
char[] process(const(char)[] input) @safe
{
    auto sink = appender!(char[])();
    process(input, sink);
    return sink.data;
}

/// ditto: appends the response to `sink`.
void process(const(char)[] input, ref Appender!(char[]) sink) @safe
{
    auto rd = LineReader(input);
    auto mode = rd.readLine();
    while (mode.length && (mode[$ - 1] == ' ' || mode[$ - 1] == '\t'))
        mode = mode[0 .. $ - 1];

    if (mode == "diff")
    {
        auto a = rd.readLines(rd.readCount());
        auto b = rd.readLines(rd.readCount());
        rd.expectEnd();
        sink.reserve(input.length + 64);
        appendScript(sink, diffLines(a, b), a, b);
    }
    else if (mode == "patch")
    {
        auto a = rd.readLines(rd.readCount());
        auto script = rd.readLines(rd.readCount());
        rd.expectEnd();
        auto result = applyScript(a, script);
        sink.reserve(input.length + 64);
        appendNumber(sink, result.length);
        sink.put('\n');
        foreach (l; result)
        {
            sink.put(l);
            sink.put('\n');
        }
    }
    else
        throw new FormatException("mode must be 'diff' or 'patch'");
}
