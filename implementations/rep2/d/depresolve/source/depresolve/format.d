/// Rendering of resolutions in the CLI output format.
module depresolve.format;

import depresolve.resolver;

/**
 * Formats a resolution: one `name version` line per pick (picks are already
 * sorted by name), or the single line `unsatisfiable`.
 */
string formatResolution(const Resolution r) pure @safe
{
    import std.array : appender;

    if (!r.satisfiable)
        return "unsatisfiable\n";
    auto app = appender!string;
    foreach (p; r.picks)
    {
        app ~= p.name;
        app ~= ' ';
        app ~= p.version_.toString;
        app ~= '\n';
    }
    return app.data;
}

unittest
{
    import depresolve.semver : Version;

    assert(formatResolution(Resolution(false)) == "unsatisfiable\n");
    assert(formatResolution(Resolution(true)) == "");
    assert(formatResolution(Resolution(true, [Pick("a", Version(1, 2, 3)),
                                              Pick("b", Version(0, 0, 1))]))
           == "a 1.2.3\nb 0.0.1\n");
}
