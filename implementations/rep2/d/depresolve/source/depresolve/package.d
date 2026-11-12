/**
 * depresolve: a deterministic package dependency resolver.
 *
 * Given a registry of package versions and a root manifest, `resolve` picks
 * one version per needed package by a depth-first, newest-first,
 * chronologically backtracking search, so every implementation prints the
 * same resolution.
 *
 * Modules:
 * $(UL
 *   $(LI `depresolve.semver`   - `Version` and `ParseException`)
 *   $(LI `depresolve.range`    - `VersionRange` (`*`, exact, `^`, `~`, comparators))
 *   $(LI `depresolve.registry` - `Registry`, `Requirement`)
 *   $(LI `depresolve.parser`   - `parseProblem` for the text input format)
 *   $(LI `depresolve.resolver` - `resolve`, `Resolution`)
 *   $(LI `depresolve.format`   - `formatResolution`)
 * )
 *
 * Example:
 * ---
 * import depresolve;
 *
 * auto problem = parseProblem("a 1.0.0: b ^1.0.0\nb 1.2.0:\nroot: a *\n");
 * auto result = resolve(problem);
 * assert(result.satisfiable);
 * assert(formatResolution(result) == "a 1.0.0\nb 1.2.0\n");
 * ---
 */
module depresolve;

public import depresolve.format;
public import depresolve.parser;
public import depresolve.range;
public import depresolve.registry;
public import depresolve.resolver;
public import depresolve.semver;

///
unittest
{
    auto problem = parseProblem("a 1.0.0: b ^1.0.0\nb 1.2.0:\nroot: a *\n");
    auto result = resolve(problem);
    assert(result.satisfiable);
    assert(formatResolution(result) == "a 1.0.0\nb 1.2.0\n");
}

/// Building a registry programmatically.
unittest
{
    Registry reg;
    reg.add("app", "1.0.0", "lib ^1.0.0");
    reg.add("lib", "1.0.0");
    reg.add("lib", "1.4.0");
    reg.add("lib", "2.0.0");
    const root = [Requirement(reg.intern("app"), parseRange("*"))];
    auto result = resolve(reg, root);
    assert(result.picks.length == 2);
    assert(result.picks[1].name == "lib" && result.picks[1].version_ == Version(1, 4, 0));
}
