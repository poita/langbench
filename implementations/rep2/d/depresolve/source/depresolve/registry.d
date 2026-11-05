/**
 * The package registry in a flat, search-friendly representation.
 *
 * Package names are interned to dense integer ids. All versions live in one
 * array, grouped by package and sorted newest first; all requirements live in
 * one array and are referenced by index. After construction every requirement
 * carries the contiguous window of candidate indices (into its target's
 * newest-first version list) that it admits, so the resolver never filters or
 * binary-searches while searching.
 *
 * Build a registry with `RegistryBuilder`, or parse the textual input format
 * with `depresolve.parser.parseInput`.
 */
module depresolve.registry;

import std.algorithm.sorting : sort;

import depresolve.range;
import depresolve.semver;

/// Sentinel used for "no such package id".
enum uint noPackage = uint.max;

/// A requirement as supplied by a caller: a package name and a range.
struct RequirementSpec
{
    string name;
    Interval range;
}

/// A resolved requirement stored in a `Registry`.
struct Requirement
{
    /// Dense id of the required package.
    uint pkg;
    /// Interval of admitted version keys.
    Interval range;
    /// Window `[first, last)` of admitted indices into the target's
    /// newest-first version list. Empty when `last <= first`.
    uint first, last;
}

/// One version of one package.
struct VersionEntry
{
    VersionKey key;
    /// Slice `[reqStart, reqStart + reqCount)` of `Registry.reqs`.
    uint reqStart, reqCount;
}

/// Immutable-after-construction registry plus the root manifest.
struct Registry
{
    /// Package name by dense id.
    string[] names;
    /// `verStart[p] .. verStart[p+1]` is package `p`'s slice of `versions`.
    uint[] verStart;
    /// All versions, grouped by package, newest first within a package.
    VersionEntry[] versions;
    /// All requirements of all versions, plus those of the root.
    Requirement[] reqs;
    /// Slice of `reqs` holding the root manifest.
    uint rootStart, rootCount;

    /// Number of distinct package names (including names only ever required).
    size_t packageCount() const pure nothrow @nogc @safe
    {
        return names.length;
    }

    /// Versions of package `pkg`, newest first.
    const(VersionEntry)[] versionsOf(uint pkg) const pure nothrow @nogc @safe
    {
        return versions[verStart[pkg] .. verStart[pkg + 1]];
    }

    /// The requirements of a version entry.
    const(Requirement)[] requirementsOf(const VersionEntry e) const pure nothrow @nogc @safe
    {
        return reqs[e.reqStart .. e.reqStart + e.reqCount];
    }

    /// The requirements of the root manifest, in order.
    const(Requirement)[] rootRequirements() const pure nothrow @nogc @safe
    {
        return reqs[rootStart .. rootStart + rootCount];
    }

    /// Id of the package called `name`, or `noPackage`.
    uint idOf(string name) const pure nothrow @safe
    {
        foreach (i, n; names)
            if (n == name)
                return cast(uint) i;
        return noPackage;
    }
}

/// Incrementally assembles a `Registry`.
struct RegistryBuilder
{
    private
    {
        struct RawVersion
        {
            uint pkg;
            VersionKey key;
            uint reqStart, reqCount;
        }

        struct RawReq
        {
            uint pkg;
            Interval range;
        }

        uint[string] ids;
        string[] names;
        RawVersion[] raw;
        RawReq[] rawReqs;
        uint rootStart, rootCount;
    }

    private uint intern(string name) pure @safe
    {
        if (auto p = name in ids)
            return *p;
        immutable id = cast(uint) names.length;
        names ~= name;
        ids[name] = id;
        return id;
    }

    private uint appendReqs(const(RequirementSpec)[] reqs) pure @safe
    {
        immutable start = cast(uint) rawReqs.length;
        foreach (r; reqs)
            rawReqs ~= RawReq(intern(r.name), r.range);
        return start;
    }

    /// Declare one version of package `name` with its requirements, in order.
    void addVersion(string name, Version version_, const(RequirementSpec)[] reqs = null) pure @safe
    {
        immutable pkg = intern(name);
        immutable start = appendReqs(reqs);
        raw ~= RawVersion(pkg, version_.key, start, cast(uint) reqs.length);
    }

    /// Set the root manifest (the requirements the resolution must satisfy).
    void setRoot(const(RequirementSpec)[] reqs) pure @safe
    {
        rootStart = appendReqs(reqs);
        rootCount = cast(uint) reqs.length;
    }

    /// Sort versions, compute candidate windows and produce the `Registry`.
    Registry build() pure @safe
    {
        immutable P = names.length;
        Registry r;
        r.names = names.dup;

        // Group versions by package (counting sort), then sort each group
        // newest first.
        auto counts = new uint[P + 1];
        foreach (ref v; raw)
            ++counts[v.pkg + 1];
        foreach (i; 0 .. P)
            counts[i + 1] += counts[i];
        r.verStart = counts.dup;
        r.versions = new VersionEntry[raw.length];
        auto fill = counts[0 .. P].dup;
        foreach (ref v; raw)
            r.versions[fill[v.pkg]++] = VersionEntry(v.key, v.reqStart, v.reqCount);
        foreach (p; 0 .. P)
            r.versions[r.verStart[p] .. r.verStart[p + 1]].sort!((a, b) => a.key > b.key);

        // Resolve each requirement's interval to a window of indices.
        r.reqs = new Requirement[rawReqs.length];
        foreach (i, ref q; rawReqs)
        {
            auto list = r.versions[r.verStart[q.pkg] .. r.verStart[q.pkg + 1]];
            uint first = 0, last = 0;
            if (!q.range.empty)
            {
                first = countAtLeast(list, q.range.hi);
                last = countAtLeast(list, q.range.lo);
            }
            r.reqs[i] = Requirement(q.pkg, q.range, first, last);
        }
        r.rootStart = rootStart;
        r.rootCount = rootCount;
        return r;
    }
}

/// Number of entries of a newest-first list whose key is `>= bound`
/// (they form a prefix). Binary search.
private uint countAtLeast(const(VersionEntry)[] list, VersionKey bound) pure nothrow @nogc @safe
{
    size_t lo = 0, hi = list.length;
    while (lo < hi)
    {
        immutable mid = lo + (hi - lo) / 2;
        if (list[mid].key >= bound)
            lo = mid + 1;
        else
            hi = mid;
    }
    return cast(uint) lo;
}
