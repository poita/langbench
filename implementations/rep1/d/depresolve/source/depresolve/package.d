/**
 * depresolve — a deterministic package dependency resolver.
 *
 * Given a registry of package versions with their requirements and a root
 * manifest, `resolve` returns the first complete solution of the specified
 * search: depth-first, newest version first, chronological backtracking.
 *
 * ---
 * import depresolve;
 *
 * auto res = resolveText("a 1.0.0: b ^1.0.0\nb 1.2.0:\nroot: a *\n");
 * assert(res.satisfiable);
 * assert(formatResolution(res) == "a 1.0.0\nb 1.2.0\n");
 * ---
 *
 * Modules: `depresolve.semver` (packed version keys), `depresolve.range`
 * (ranges as intervals), `depresolve.registry` (parsing and indexing),
 * `depresolve.resolver` (the search).
 */
module depresolve;

public import depresolve.semver;
public import depresolve.range;
public import depresolve.registry;
public import depresolve.resolver;
