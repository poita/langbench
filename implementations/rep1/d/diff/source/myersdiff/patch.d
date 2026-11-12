/// Applying an edit script to a file, in one pass.
module myersdiff.patch;

import myersdiff.edit;
import myersdiff.intern : Line;
import myersdiff.script;

/// Thrown when a script is not valid for the file it is applied to.
class PatchException : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) @safe pure nothrow
    {
        super(msg, file, line);
    }
}

/**
 * Applies `script` to the lines `a` and returns the resulting lines.
 *
 * The script need not be minimal. It must be valid for `a`: its keep and
 * delete lines, in order, must be exactly the lines of `a`; otherwise a
 * `PatchException` is thrown. Runs in O(total size).
 */
Line[] applyScript(scope const(Line)[] a, scope const(ScriptLine)[] script) @safe pure
{
    auto result = new Line[](0);
    result.reserve(script.length);
    size_t pos;
    foreach (s; script)
    {
        final switch (s.kind)
        {
        case EditKind.keep:
        case EditKind.remove:
            if (pos >= a.length)
                throw new PatchException("script consumes more lines than the file has");
            if (a[pos] != s.text)
                throw new PatchException("script line does not match the file");
            if (s.kind == EditKind.keep)
                result ~= a[pos];
            ++pos;
            break;
        case EditKind.insert:
            result ~= s.text;
            break;
        }
    }
    if (pos != a.length)
        throw new PatchException("script does not consume the whole file");
    return result;
}

///
@safe pure unittest
{
    const(Line)[] a = ["a", "b", "c", "d", "e"];
    auto script = parseScript([" a", "-b", "+B", " c", "+c2", "-d", " e", "+f"]);
    assert(applyScript(a, script) == ["a", "B", "c", "c2", "e", "f"]);
}

@safe pure unittest
{
    import std.exception : assertThrown;
    // Non-minimal scripts are fine.
    assert(applyScript(["a"], parseScript(["-a", "+a"])) == ["a"]);
    assert(applyScript([], parseScript([])) == []);
    assertThrown!PatchException(applyScript(["a"], parseScript([" b"])));
    assertThrown!PatchException(applyScript(["a"], parseScript([])));
    assertThrown!PatchException(applyScript([], parseScript(["-a"])));
}
