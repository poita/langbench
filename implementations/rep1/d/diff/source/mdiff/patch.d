/// Applying edit scripts to a file.
module mdiff.patch;

import mdiff.errors;

/**
 * Applies a textual edit script to the lines `a` and returns the lines of the
 * result.
 *
 * Each script line is a tag character (` `, `-`, `+`) followed by the line
 * text. The returned lines are views into `a` and `script`; nothing is copied.
 * Throws $(REF PatchException, mdiff.errors) if the script is malformed or
 * does not match `a`.
 */
const(char)[][] applyScript(scope const(const(char)[])[] a, scope const(const(char)[])[] script) @safe
{
    auto result = new const(char)[][](0);
    result.reserve(a.length + script.length);
    size_t next; // next unconsumed line of a
    foreach (line; script)
    {
        if (line.length == 0)
            throw new PatchException("empty script line (missing tag)");
        const text = line[1 .. $];
        switch (line[0])
        {
        case ' ':
        case '-':
            if (next >= a.length)
                throw new PatchException("script consumes more lines than the file has");
            if (a[next] != text)
                throw new PatchException("script line does not match the file");
            if (line[0] == ' ')
                result ~= a[next];
            ++next;
            break;
        case '+':
            result ~= text;
            break;
        default:
            throw new PatchException("invalid tag in script line");
        }
    }
    if (next != a.length)
        throw new PatchException("script does not consume the whole file");
    return result;
}
