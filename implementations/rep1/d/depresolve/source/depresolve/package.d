/**
 * depresolve: a deterministic package dependency resolver.
 *
 * Given a registry of package versions (each with requirements expressed as
 * semver ranges) and a root manifest, `resolve` picks one version for every
 * package that is needed using a fully specified search: depth-first,
 * newest version first, chronological backtracking. Equal inputs therefore
 * always give equal resolutions.
 *
 * Modules:
 * $(UL
 *   $(LI `depresolve.semver`   – `Version`, `VersionRange`)
 *   $(LI `depresolve.registry` – `Registry`, `Dependency`)
 *   $(LI `depresolve.parser`   – text format → `Problem`)
 *   $(LI `depresolve.resolver` – the `resolve` search)
 *   $(LI `depresolve.output`   – `formatResolution`)
 * )
 */
module depresolve;

public import depresolve.semver;
public import depresolve.registry;
public import depresolve.parser;
public import depresolve.resolver;
public import depresolve.output;
