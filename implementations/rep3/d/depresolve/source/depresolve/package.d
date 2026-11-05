/**
 * depresolve: a deterministic package dependency resolver.
 *
 * Given a registry of package versions (each with requirements) and a root
 * manifest, it picks one version for every needed package by depth-first,
 * newest-first search with chronological backtracking, and reports the first
 * complete solution found.
 *
 * Modules:
 * $(UL
 *   $(LI `depresolve.semver`   - packed, order-preserving `Version`)
 *   $(LI `depresolve.range`    - ranges as half-open key intervals, parsing)
 *   $(LI `depresolve.registry` - registry/manifest parsing into flat arrays)
 *   $(LI `depresolve.resolver` - the iterative backtracking search)
 *   $(LI `depresolve.output`   - rendering results)
 * )
 */
module depresolve;

public import depresolve.semver;
public import depresolve.range;
public import depresolve.registry;
public import depresolve.resolver;
public import depresolve.output;

/**
 * Parses `input` (registry lines followed by a root line) and returns the
 * formatted resolution, ready to be printed.
 */
string resolveText(string input) @safe
{
    static import depresolve.output;

    auto reg = Registry.parse(input);
    auto res = resolve(reg);
    return depresolve.output.format(res);
}

///
@safe unittest
{
    assert(resolveText("a 1.0.0:\nroot: a *\n") == "a 1.0.0\n");
}
