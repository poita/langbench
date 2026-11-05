/// Rendering edit scripts to the textual format (` `, `-`, `+` tags).
module mdiff.script;

import std.array : Appender;
import mdiff.edit;

/**
 * Appends the textual script for `edits` to `sink`: the count line, then one
 * line per edit (tag character followed by the line text), each ending in
 * `\n`. `a` and `b` supply the line text the edits refer to.
 */
void appendScript(ref Appender!(char[]) sink, scope const(Edit)[] edits,
        scope const(const(char)[])[] a, scope const(const(char)[])[] b) @safe
{
    appendNumber(sink, edits.length);
    sink.put('\n');
    foreach (e; edits)
    {
        sink.put(tagOf(e.kind));
        sink.put(e.kind == EditKind.insert ? b[e.index] : a[e.index]);
        sink.put('\n');
    }
}

/// Appends `n` in decimal (no sign, no leading zeros).
void appendNumber(ref Appender!(char[]) sink, size_t n) @safe
{
    char[20] tmp = void;
    size_t i = tmp.length;
    do
    {
        tmp[--i] = cast(char)('0' + n % 10);
        n /= 10;
    }
    while (n);
    sink.put(tmp[i .. $]);
}
