/// Rendering of resolutions in the command-line output format.
module depresolve.output;

import std.array : appender;
import depresolve.resolver : Resolution;

/**
 * Formats a resolution: one `name version` line per picked package (already
 * sorted by name), or the single line `unsatisfiable` when the search failed.
 * Every line ends with `\n`; a successful empty resolution yields `""`.
 */
string formatResolution(const Resolution r) @safe
{
    if (!r.success)
        return "unsatisfiable\n";
    auto app = appender!string;
    foreach (ref p; r.picks)
    {
        app.put(p.name);
        app.put(' ');
        app.put(p.version_.toString);
        app.put('\n');
    }
    return app.data;
}

@safe unittest
{
    import depresolve.resolver : Pick;
    import depresolve.semver : Version;
    assert(formatResolution(Resolution(false)) == "unsatisfiable\n");
    assert(formatResolution(Resolution(true)) == "");
    assert(formatResolution(Resolution(true, [Pick("a", Version(1, 2, 3)), Pick("b", Version(0, 0, 1))]))
        == "a 1.2.3\nb 0.0.1\n");
}
