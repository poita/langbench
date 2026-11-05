/**
 * The package registry and root manifest, parsed into flat arrays.
 *
 * Package names are interned to dense integer ids. All versions of all
 * packages live in one array grouped by package and sorted newest first, so a
 * package's candidate versions are a contiguous slice and the versions a
 * requirement admits are a contiguous *window* inside that slice, computed
 * once after parsing with two binary searches.
 */
module depresolve.registry;

import std.algorithm : sort;
import depresolve.range;
import depresolve.semver;

/// One requirement `name range`, with its precomputed candidate window.
struct Requirement
{
    /// Id of the required package.
    uint pkg;
    /// The accepted versions as an interval of keys.
    Interval range;
    /// First admitted position in `Registry.versions` (newest admitted version).
    uint first;
    /// One past the last admitted position; `last <= first` means no candidates.
    uint last;
}

/// The parsed registry together with the root manifest.
struct Registry
{
    /// Package name by package id.
    string[] names;
    /// Every requirement of every version and of the root, stored once.
    Requirement[] reqs;
    /// All versions, grouped by package id and newest first within a package.
    Version[] versions;
    /// Index into `reqs` of the first requirement of `versions[i]`.
    uint[] reqStart;
    /// Number of requirements of `versions[i]`.
    uint[] reqCount;
    /// `versions[pkgStart[p] .. pkgEnd[p]]` are the versions of package `p`.
    uint[] pkgStart;
    /// ditto
    uint[] pkgEnd;
    /// Index into `reqs` of the first root requirement.
    uint rootStart;
    /// Number of root requirements.
    uint rootCount;

    /// Number of distinct package names (registry lines and requirements).
    @property size_t packageCount() const pure nothrow @nogc @safe
    {
        return names.length;
    }

    /// The requirements of the version stored at position `i` of `versions`.
    const(Requirement)[] requirementsOf(size_t i) const pure nothrow @nogc @safe
    {
        return reqs[reqStart[i] .. reqStart[i] + reqCount[i]];
    }

    /// The requirements of the root manifest, in the order written.
    const(Requirement)[] rootRequirements() const pure nothrow @nogc @safe
    {
        return reqs[rootStart .. rootStart + rootCount];
    }

    /**
     * Parses the whole input text (registry lines followed by the root line).
     * Throws `ParseException` on malformed input.
     */
    static Registry parse(string text) @safe
    {
        return Parser(text).run();
    }
}

private struct RawVersion
{
    uint pkg;
    ulong key;
    uint reqStart;
    uint reqCount;
}

private struct Parser
{
    string s;
    size_t pos;
    uint[string] ids;
    Registry reg;
    RawVersion[] raw;

    this(string text) @safe
    {
        s = text;
    }

    uint intern(string name) @safe
    {
        if (auto p = name in ids)
            return *p;
        const id = cast(uint) reg.names.length;
        ids[name] = id;
        reg.names ~= name;
        return id;
    }

    string readName() @safe
    {
        const start = pos;
        while (pos < s.length && ((s[pos] >= 'a' && s[pos] <= 'z')
                || (s[pos] >= '0' && s[pos] <= '9') || s[pos] == '-'))
            ++pos;
        if (pos == start)
            throw new ParseException("expected package name");
        return s[start .. pos];
    }

    void expect(char c) @safe
    {
        if (pos >= s.length || s[pos] != c)
            throw new ParseException("expected '" ~ c ~ "'");
        ++pos;
    }

    /// Parses the text after the colon up to and including the newline.
    uint requirements() @safe
    {
        uint count = 0;
        if (pos < s.length && s[pos] == ' ')
        {
            ++pos;
            while (true)
            {
                const pkg = intern(readName());
                expect(' ');
                const range = parseRange(s, pos);
                reg.reqs ~= Requirement(pkg, range, 0, 0);
                ++count;
                if (pos + 1 < s.length && s[pos] == ',' && s[pos + 1] == ' ')
                    pos += 2;
                else
                    break;
            }
        }
        // Tolerate a missing final newline.
        if (pos < s.length)
            expect('\n');
        return count;
    }

    Registry run() @safe
    {
        bool haveRoot = false;
        while (pos < s.length)
        {
            if (s.length - pos >= 5 && s[pos .. pos + 5] == "root:")
            {
                pos += 5;
                reg.rootStart = cast(uint) reg.reqs.length;
                reg.rootCount = requirements();
                haveRoot = true;
                break;
            }
            const name = readName();
            expect(' ');
            const ver = parseVersion(s, pos);
            expect(':');
            const start = cast(uint) reg.reqs.length;
            const count = requirements();
            raw ~= RawVersion(intern(name), ver.key, start, count);
        }
        if (!haveRoot)
            throw new ParseException("missing root line");
        finish();
        return reg;
    }

    /// Sorts the versions and resolves every requirement to an index window.
    void finish() @safe
    {
        const nPkgs = reg.names.length;
        raw.sort!((a, b) => a.pkg != b.pkg ? a.pkg < b.pkg : a.key > b.key);
        reg.pkgStart = new uint[nPkgs];
        reg.pkgEnd = new uint[nPkgs];
        reg.versions = new Version[raw.length];
        reg.reqStart = new uint[raw.length];
        reg.reqCount = new uint[raw.length];
        foreach (i, ref r; raw)
        {
            reg.versions[i] = Version.fromKey(r.key);
            reg.reqStart[i] = r.reqStart;
            reg.reqCount[i] = r.reqCount;
            reg.pkgEnd[r.pkg] = cast(uint) i + 1;
        }
        // Packages without versions keep an empty [0, 0) slice; others get a start.
        foreach_reverse (i, ref r; raw)
            reg.pkgStart[r.pkg] = cast(uint) i;

        foreach (ref q; reg.reqs)
        {
            const s0 = reg.pkgStart[q.pkg];
            const e0 = reg.pkgEnd[q.pkg];
            if (q.range.empty || e0 <= s0)
            {
                q.first = q.last = 0;
                continue;
            }
            // Keys are descending: skip those >= hi, then take those >= lo.
            q.first = lowerBound(s0, e0, (k) => k >= q.range.hi);
            q.last = lowerBound(q.first, e0, (k) => k >= q.range.lo);
            if (q.last < q.first)
                q.last = q.first;
        }
    }

    /// First position in [lo, hi) whose key does NOT satisfy `skip` (a prefix predicate).
    uint lowerBound(uint lo, uint hi, scope bool delegate(ulong) @safe skip) @safe
    {
        while (lo < hi)
        {
            const mid = lo + (hi - lo) / 2;
            if (skip(reg.versions[mid].key))
                lo = mid + 1;
            else
                hi = mid;
        }
        return lo;
    }
}
