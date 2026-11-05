/**
 * The package registry and root manifest in a flat, integer-indexed form.
 *
 * Package names are interned to dense ids, versions are packed into
 * `VersionKey`s, and every requirement becomes `(package id, interval)`.
 * Once parsing is done, `Registry.finalize` sorts each package's versions
 * newest first and converts every requirement's interval into the window of
 * candidate indices it admits, so that the search never filters versions.
 */
module depresolve.registry;

import depresolve.range;
import depresolve.semver;

/// Sentinel for "no package" / "not chosen".
enum uint none = uint.max;

/// One requirement: a target package and the versions it accepts.
struct Requirement
{
    /// Dense id of the required package.
    uint pkg;
    /// Accepted versions as `[lo, hi)` of version keys.
    Interval interval;
    /// Window `[first, last)` of admissible candidate indices into the
    /// target's newest-first version list. Filled in by `Registry.finalize`.
    uint first;
    /// ditto
    uint last;

    /// True when candidate index `idx` of the target package is admitted.
    bool admits(uint idx) const @safe pure nothrow @nogc
    {
        return idx >= first && idx < last;
    }
}

/// One declared package version and the slice of requirements it owns.
struct PackageVersion
{
    uint pkg;
    VersionKey key;
    /// Index of the first requirement in `Registry.requirements`.
    uint reqStart;
    /// Number of requirements.
    uint reqCount;
}

/// A parsed registry plus root manifest.
struct Registry
{
    /// Package name by id.
    string[] names;
    /// Every declared package version.
    PackageVersion[] versions;
    /// All requirements of all lines (root included), referenced by slice.
    Requirement[] requirements;
    /// Slice of `requirements` that belongs to the root manifest.
    uint rootStart, rootCount;

    /// `candidates[pkgStart[p] .. pkgStart[p+1]]` are the indices (into
    /// `versions`) of package `p`'s versions, newest first.
    uint[] pkgStart;
    /// ditto
    uint[] candidates;

    private uint[string] ids;

    /// Number of distinct package names (including ones only required).
    size_t packageCount() const @safe pure nothrow @nogc
    {
        return names.length;
    }

    /// Returns the id of `name`, adding it if unseen.
    uint intern(const(char)[] name) @safe pure nothrow
    {
        if (auto p = name in ids)
            return *p;
        const id = cast(uint) names.length;
        const s = name.idup;
        names ~= s;
        ids[s] = id;
        return id;
    }

    /// Returns the id of `name`, or `none` when the package is unknown.
    uint lookup(const(char)[] name) const @safe pure nothrow
    {
        if (auto p = name in ids)
            return *p;
        return none;
    }

    /// Candidate version indices (into `versions`) of package `pkg`, newest first.
    const(uint)[] candidatesOf(uint pkg) const @safe pure nothrow @nogc
    {
        return candidates[pkgStart[pkg] .. pkgStart[pkg + 1]];
    }

    /// Sorts every package's versions newest first and resolves every
    /// requirement's interval to a candidate window. Call once after parsing.
    void finalize() @safe pure nothrow
    {
        import std.algorithm.sorting : sort;

        const p = names.length;
        auto start = new uint[p + 1];
        foreach (ref v; versions)
            ++start[v.pkg + 1];
        foreach (i; 0 .. p)
            start[i + 1] += start[i];
        auto fill = start[0 .. p].dup;
        auto cands = new uint[versions.length];
        foreach (i, ref v; versions)
            cands[fill[v.pkg]++] = cast(uint) i;
        foreach (i; 0 .. p)
        {
            auto seg = cands[start[i] .. start[i + 1]];
            if (seg.length > 1)
            {
                const vs = versions;
                seg.sort!((a, b) => vs[a].key > vs[b].key);
            }
        }
        pkgStart = start;
        candidates = cands;

        foreach (ref r; requirements)
        {
            const seg = cands[start[r.pkg] .. start[r.pkg + 1]];
            if (r.interval.empty)
            {
                r.first = r.last = 0;
                continue;
            }
            // Newest first: entries with key >= hi come first, then those in
            // [lo, hi), then those below lo.
            r.first = cast(uint) countAtLeast(seg, r.interval.hi);
            r.last = cast(uint) countAtLeast(seg, r.interval.lo);
            if (r.last < r.first)
                r.last = r.first;
        }
    }

    // Number of leading entries of the newest-first `seg` whose key >= bound.
    private size_t countAtLeast(const(uint)[] seg, VersionKey bound) const @safe pure nothrow @nogc
    {
        size_t lo = 0, hi = seg.length;
        while (lo < hi)
        {
            const mid = lo + (hi - lo) / 2;
            if (versions[seg[mid]].key >= bound)
                lo = mid + 1;
            else
                hi = mid;
        }
        return lo;
    }
}

/**
 * Parses the input format (registry lines followed by one root line) and
 * returns a finalized `Registry`.
 *
 * The input is assumed to be well formed.
 */
Registry parseRegistry(const(char)[] text) @safe pure
{
    Registry reg;
    reg.requirements.reserve(text.length / 12 + 4);

    while (text.length)
    {
        size_t eol = 0;
        while (eol < text.length && text[eol] != '\n')
            ++eol;
        auto line = text[0 .. eol];
        text = eol < text.length ? text[eol + 1 .. $] : text[eol .. $];
        if (line.length == 0)
            continue;

        if (line.length >= 5 && line[0 .. 5] == "root:")
        {
            reg.rootStart = cast(uint) reg.requirements.length;
            parseRequirements(reg, line[5 .. $]);
            reg.rootCount = cast(uint) reg.requirements.length - reg.rootStart;
            break;
        }

        size_t sp = 0;
        while (line[sp] != ' ')
            ++sp;
        const pkg = reg.intern(line[0 .. sp]);
        auto rest = line[sp + 1 .. $];
        const key = parseVersion(rest);
        // rest now starts at ':'
        PackageVersion pv;
        pv.pkg = pkg;
        pv.key = key;
        pv.reqStart = cast(uint) reg.requirements.length;
        parseRequirements(reg, rest[1 .. $]);
        pv.reqCount = cast(uint) reg.requirements.length - pv.reqStart;
        reg.versions ~= pv;
    }
    reg.finalize();
    return reg;
}

// Parses `" name range, name range"` (or the empty string), appending to reg.requirements.
private void parseRequirements(ref Registry reg, const(char)[] text) @safe pure
{
    if (text.length && text[0] == ' ')
        text = text[1 .. $];
    while (text.length)
    {
        size_t end = 0;
        while (end < text.length && text[end] != ',')
            ++end;
        const item = text[0 .. end];
        text = end < text.length ? text[end + 1 .. $] : text[end .. $];
        if (text.length && text[0] == ' ')
            text = text[1 .. $];

        size_t sp = 0;
        while (sp < item.length && item[sp] != ' ')
            ++sp;
        Requirement r;
        r.pkg = reg.intern(item[0 .. sp]);
        r.interval = parseRange(sp < item.length ? item[sp + 1 .. $] : "*");
        reg.requirements ~= r;
    }
}
