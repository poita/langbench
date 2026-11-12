/**
 * The package registry: every version of every package together with its
 * requirements, preprocessed for the resolver.
 *
 * Packages are interned to dense integer ids. When a registry is sealed
 * (see `Registry.seal`) the versions of each package are sorted newest
 * first and every requirement is bound to the contiguous index range of
 * candidate versions it admits, so the search never filters versions.
 */
module depresolve.registry;

import depresolve.range;
import depresolve.semver;

/// Dense identifier of a package within one `Registry`.
alias PackageId = uint;

/// Marks "no index" / "no package".
enum uint none = uint.max;

/**
 * A requirement `name range`.
 *
 * `first` and `last` are filled in by `Registry.seal` / `Registry.bind`:
 * the candidates are the versions at indices `[first, last)` of the target
 * package's newest-first version list.
 */
struct Requirement
{
    /// Target package.
    PackageId pkg;
    /// Accepted versions.
    VersionRange range;
    /// First candidate index (newest-first order), valid once bound.
    uint first;
    /// One past the last candidate index, valid once bound.
    uint last;
}

/// One version of a package and the slice of the requirement pool it owns.
struct PackageVersion
{
    /// The version.
    Version version_;
    /// Requirements occupy `Registry.pool[reqStart .. reqEnd]`.
    uint reqStart, reqEnd;
}

/// A package and all its versions.
struct Package
{
    /// Package name.
    string name;
    /// Versions; newest first once the registry is sealed.
    PackageVersion[] versions;
}

/// A registry of package versions.
struct Registry
{
    /// All packages, indexed by `PackageId`.
    Package[] packages;
    /// Requirements of all versions, stored contiguously.
    Requirement[] pool;

    private PackageId[string] ids;
    private bool sealed_ = true;

    /// Returns the id of `name`, interning it if it is new.
    PackageId intern(string name) pure @safe
    {
        if (auto p = name in ids)
            return *p;
        const id = cast(PackageId) packages.length;
        packages ~= Package(name);
        ids[name] = id;
        return id;
    }

    /// Looks up a package id without interning; `none` if unknown.
    PackageId find(const(char)[] name) const pure @safe
    {
        if (auto p = name in ids)
            return *p;
        return none;
    }

    /**
     * Declares package version `name version_` with the given requirements.
     * Requirements must target ids obtained from `intern`.
     */
    void add(string name, Version version_, const(Requirement)[] reqs) pure @safe
    {
        const id = intern(name);
        const start = cast(uint) pool.length;
        pool ~= reqs;
        packages[id].versions ~= PackageVersion(version_, start, cast(uint) pool.length);
        sealed_ = false;
    }

    /// Convenience: declares a version from textual `name`, `version` and
    /// `requirements` of the form `"dep ^1.0.0, other *"`.
    void add(string name, string version_, string requirements = "") pure @safe
    {
        import std.array : split;
        import std.string : indexOf, strip;

        Requirement[] reqs;
        if (requirements.strip.length)
        {
            size_t pos = 0;
            while (true)
            {
                const sp = requirements.indexOf(' ', pos);
                if (sp < 0)
                    throw new ParseException("malformed requirement: " ~ requirements);
                const depName = requirements[pos .. sp];
                pos = sp + 1;
                const range = parseRangeAt(requirements, pos);
                reqs ~= Requirement(intern(depName.idup), range);
                if (pos >= requirements.length)
                    break;
                if (pos + 1 < requirements.length && requirements[pos .. pos + 2] == ", ")
                    pos += 2;
                else
                    throw new ParseException("malformed requirement list: " ~ requirements);
            }
        }
        add(name, parseVersion(version_), reqs);
    }

    /// True once `seal` has run since the last modification.
    bool sealed() const pure nothrow @nogc @safe { return sealed_; }

    /**
     * Sorts every package's versions newest first and binds every stored
     * requirement to its candidate index range. Idempotent; called
     * automatically by the resolver.
     */
    void seal() pure @safe
    {
        if (sealed_)
            return;
        import std.algorithm.sorting : sort;
        foreach (ref p; packages)
            p.versions.sort!((a, b) => a.version_ > b.version_);
        foreach (ref r; pool)
            bind(r);
        sealed_ = true;
    }

    /// Fills in `r.first` / `r.last` for a requirement against the sealed
    /// registry (binary search over the newest-first version list).
    void bind(ref Requirement r) const pure nothrow @nogc @safe
    {
        const vs = packages[r.pkg].versions;
        // First index whose version is < hi (everything before is too new).
        r.first = partitionPoint(vs, (const Version v) => v >= r.range.hi);
        // First index whose version is < lo (everything from here is too old).
        r.last = partitionPoint(vs, (const Version v) => v >= r.range.lo);
        if (r.last < r.first)
            r.last = r.first;
    }

    /// Number of versions of package `id`.
    size_t versionCount(PackageId id) const pure nothrow @nogc @safe
    {
        return packages[id].versions.length;
    }
}

/// Index of the first element of `vs` for which `pred(version)` is false,
/// assuming `pred` is true for a prefix.
private uint partitionPoint(Pred)(const(PackageVersion)[] vs, scope Pred pred)
    pure nothrow @nogc @safe
{
    size_t lo = 0, hi = vs.length;
    while (lo < hi)
    {
        const mid = lo + (hi - lo) / 2;
        if (pred(vs[mid].version_))
            lo = mid + 1;
        else
            hi = mid;
    }
    return cast(uint) lo;
}

unittest
{
    Registry reg;
    reg.add("a", "1.9.0");
    reg.add("a", "1.10.0");
    reg.add("a", "2.0.0");
    reg.add("a", "0.1.0");
    reg.seal();
    assert(reg.sealed);
    const id = reg.find("a");
    assert(id != none);
    string[] order;
    foreach (pv; reg.packages[id].versions)
        order ~= pv.version_.toString;
    assert(order == ["2.0.0", "1.10.0", "1.9.0", "0.1.0"]);

    auto r = Requirement(id, parseRange("^1.0.0"));
    reg.bind(r);
    assert(r.first == 1 && r.last == 3);

    auto none_ = Requirement(id, parseRange(">=3.0.0"));
    reg.bind(none_);
    assert(none_.first == none_.last);

    auto empty = Requirement(id, parseRange(">=2.0.0 <1.0.0"));
    reg.bind(empty);
    assert(empty.first == empty.last);

    auto all = Requirement(id, parseRange("*"));
    reg.bind(all);
    assert(all.first == 0 && all.last == 4);
}

unittest
{
    Registry reg;
    reg.add("app", "1.0.0", "lib ^1.0.0, util >=1.0.0 <2.0.0");
    reg.add("lib", "1.2.0");
    reg.seal();
    assert(reg.pool.length == 2);
    assert(reg.packages[reg.find("util")].versions.length == 0);
    assert(reg.pool[1].first == reg.pool[1].last);
}
