/**
 * The package registry: every known version of every package together with
 * its dependency requirements.
 */
module depresolve.registry;

import depresolve.semver;

/// A requirement: the named package must be picked at a version in `range`.
struct Dependency
{
    string name;        /// Name of the required package.
    VersionRange range; /// Versions of it that are acceptable.
}

/// One published version of a package and the requirements it declares.
struct PackageVersion
{
    string name;           /// Package name.
    Version version_;      /// Version.
    Dependency[] dependencies; /// Requirements, in declaration order.
}

/**
 * A mutable collection of package versions.
 *
 * Versions may be added in any order, interleaved across packages.
 * Dependencies may name packages that have no versions at all.
 */
struct Registry
{
    /// All entries in insertion order.
    PackageVersion[] entries;

    /// Adds a package version.
    void add(string name, Version v, Dependency[] dependencies = null) pure nothrow @safe
    {
        entries ~= PackageVersion(name, v, dependencies);
    }

    /// Convenience overload accepting version and range strings.
    void add(string name, string v, string[2][] dependencies...) @safe
    {
        Dependency[] deps;
        foreach (d; dependencies)
            deps ~= Dependency(d[0], VersionRange.parse(d[1]));
        add(name, Version.parse(v), deps);
    }
}

@safe unittest
{
    Registry r;
    r.add("a", "1.0.0", ["b", "^1.0.0"], ["c", "*"]);
    r.add("b", "1.2.0");
    assert(r.entries.length == 2);
    assert(r.entries[0].dependencies.length == 2);
    assert(r.entries[0].dependencies[0].name == "b");
    assert(r.entries[0].dependencies[0].range.contains(Version(1, 5, 0)));
    assert(r.entries[1].dependencies.length == 0);
}
