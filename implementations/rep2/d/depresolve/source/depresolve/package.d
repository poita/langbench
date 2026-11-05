/**
 * depresolve: a deterministic package dependency resolver.
 *
 * Given a registry of package versions and a root manifest, `resolve` returns
 * the first complete solution of a depth-first, newest-first search with
 * chronological backtracking.
 *
 * ---
 * import depresolve;
 *
 * auto reg = parseInput("a 1.0.0: b ^1.0.0\nb 1.2.0:\nroot: a *\n");
 * auto res = resolve(reg);
 * assert(formatResolution(res) == "a 1.0.0\nb 1.2.0\n");
 * ---
 *
 * Modules:
 * $(UL
 *   $(LI `depresolve.semver`: versions and packed keys)
 *   $(LI `depresolve.range`: ranges as key intervals)
 *   $(LI `depresolve.registry`: registry data and `RegistryBuilder`)
 *   $(LI `depresolve.parser`: textual input format)
 *   $(LI `depresolve.resolver`: the search and output formatting))
 */
module depresolve;

public import depresolve.semver;
public import depresolve.range;
public import depresolve.registry;
public import depresolve.parser;
public import depresolve.resolver;

/// Parse `input` and resolve it, returning the SPEC's output text.
string solve(string input) pure @safe
{
    auto reg = parseInput(input);
    auto res = resolve(reg);
    return formatResolution(res);
}
