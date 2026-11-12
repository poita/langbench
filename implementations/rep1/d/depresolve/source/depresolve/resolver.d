/**
 * The resolution search.
 *
 * Implements exactly the search procedure of the specification:
 * depth-first, packages fixed by the first requirement that reaches them,
 * candidates tried newest first, chronological backtracking.
 *
 * ---
 * resolve(pending, chosen):
 *     if pending is empty: return chosen
 *     (name, range) = head(pending)
 *     if name in chosen: check chosen[name] against range, else FAIL
 *     for version in candidates(name, range), newest first:
 *         result = resolve(requirements(name, version) ++ tail(pending),
 *                          chosen + {name: version})
 *         if result != FAIL: return result
 *     return FAIL
 * ---
 *
 * The implementation is iterative (so recursion depth is no concern) and
 * each search step is O(1) plus the requirements it pushes:
 *
 * $(UL
 *   $(LI Package names are interned; each package's versions are sorted
 *        newest first and every requirement is pre-converted into the
 *        contiguous index interval of candidates it admits (binary search,
 *        once).)
 *   $(LI The pending requirements are a persistent singly linked list held
 *        in an arena; pushing a version's requirements conses in front of
 *        the existing list, so choice points share structure instead of
 *        copying. Backtracking just truncates the arena.)
 *   $(LI The `chosen` map is an array indexed by package id; the stack of
 *        choice points doubles as the trail: popping a choice point undoes
 *        its package's assignment.)
 * )
 */
module depresolve.resolver;

import std.algorithm : sort;

import depresolve.registry;
import depresolve.semver;

/// A package pinned to a version in a resolution.
struct Pick
{
    string name;       /// Package name.
    Version version_;  /// Chosen version.
}

/// Outcome of `resolve`.
struct Resolution
{
    /// True if the search found a solution.
    bool success;
    /// The chosen packages sorted by name in ascending byte order (empty on failure).
    Pick[] picks;
    /// Number of choice points opened by the search (a measure of work).
    ulong choicePoints;
}

private enum uint nil = uint.max;

/// A requirement compiled to indices.
private struct CReq
{
    uint pkg;  // package id
    uint from; // first admitted candidate (local index, newest = 0)
    uint to;   // one past the last admitted candidate
}

/// Registry compiled for searching.
private struct Index
{
    string[] names;      // package id -> name
    uint[] verStart;     // package id -> first global version slot; length P + 1
    Version[] versions;  // global version slot -> version (per package: newest first)
    uint[] reqStart;     // global version slot -> first requirement; length V + 1
    CReq[] reqs;         // requirements of all versions, then the root requirements
    uint rootStart;      // root requirements are reqs[rootStart .. $]
}

private Index compile(const Registry registry, const Dependency[] root) @safe pure
{
    Index ix;

    // Intern every name that appears anywhere.
    uint[string] ids;
    uint intern(string n) @safe pure
    {
        if (auto p = n in ids)
            return *p;
        immutable id = cast(uint) ix.names.length;
        ix.names ~= n;
        ids[n] = id;
        return id;
    }
    foreach (ref e; registry.entries)
    {
        intern(e.name);
        foreach (ref d; e.dependencies) intern(d.name);
    }
    foreach (ref d; root) intern(d.name);

    immutable P = ix.names.length;

    // Bucket entries per package, then sort each bucket newest first.
    auto counts = new uint[P + 1];
    foreach (ref e; registry.entries) ++counts[ids[e.name] + 1];
    foreach (i; 1 .. P + 1) counts[i] += counts[i - 1];
    ix.verStart = counts.dup;

    auto order = new uint[registry.entries.length]; // global slot -> entry index
    auto fill = counts[0 .. P].dup;
    foreach (i, ref e; registry.entries)
        order[fill[ids[e.name]]++] = cast(uint) i;
    foreach (p; 0 .. P)
    {
        auto bucket = order[ix.verStart[p] .. ix.verStart[p + 1]];
        bucket.sort!((a, b) => registry.entries[a].version_ > registry.entries[b].version_);
    }

    ix.versions = new Version[order.length];
    foreach (slot, entry; order) ix.versions[slot] = registry.entries[entry].version_;

    // Convert a dependency to its index interval by binary search.
    CReq convert(ref const Dependency d) @safe pure
    {
        immutable p = ids[d.name];
        auto vs = ix.versions[ix.verStart[p] .. ix.verStart[p + 1]];
        // vs is sorted descending. Candidates: lo <= v < hi.
        // from = number of versions >= hi ; to = number of versions >= lo.
        uint countAtLeast(Version bound) @safe pure
        {
            size_t l = 0, h = vs.length;
            while (l < h)
            {
                immutable m = l + (h - l) / 2;
                if (vs[m] >= bound) l = m + 1; else h = m;
            }
            return cast(uint) l;
        }
        if (d.range.empty)
            return CReq(p, 0, 0);
        return CReq(p, countAtLeast(d.range.hi), countAtLeast(d.range.lo));
    }

    ix.reqStart = new uint[order.length + 1];
    foreach (slot, entry; order)
    {
        ix.reqStart[slot] = cast(uint) ix.reqs.length;
        foreach (ref d; registry.entries[entry].dependencies)
            ix.reqs ~= convert(d);
    }
    ix.reqStart[order.length] = cast(uint) ix.reqs.length;
    ix.rootStart = cast(uint) ix.reqs.length;
    foreach (ref d; root) ix.reqs ~= convert(d);
    return ix;
}

/// A node of the persistent pending-requirements list.
private struct Node
{
    uint req;  // index into Index.reqs
    uint next; // next node, or nil
}

/// An open choice: a package whose candidates are being tried in order.
private struct Choice
{
    uint pkg;       // package being chosen
    uint cur;       // next candidate (local index) to try
    uint end;       // one past the last candidate
    uint rest;      // pending list that follows the requirement that opened this choice
    uint arenaTop;  // arena size to restore when moving to the next candidate
}

/**
 * Resolves `root` against `registry` using the specified search order.
 *
 * Returns: a `Resolution`; on success `picks` lists every reached package
 * with its chosen version, sorted by name.
 */
Resolution resolve(const Registry registry, const Dependency[] root) @safe pure
{
    auto ix = compile(registry, root);
    immutable P = ix.names.length;

    auto chosen = new uint[P];     // package id -> chosen local candidate index or nil
    chosen[] = nil;

    Node[] arena = new Node[256];
    size_t arenaLen = 0;
    Choice[] stack;                // open choice points (also the trail)
    stack.reserve(P);

    uint pending = nil;

    void pushRange(uint first, uint last) @safe pure nothrow
    {
        // Prepend requirements first..last-1 so that `first` ends up at the head.
        foreach_reverse (i; first .. last)
        {
            if (arenaLen == arena.length) arena.length = arena.length * 2;
            arena[arenaLen++] = Node(i, pending);
            pending = cast(uint) (arenaLen - 1);
        }
    }

    pushRange(ix.rootStart, cast(uint) ix.reqs.length);

    // Moves the top choice point to its next candidate. Returns false (after
    // undoing the choice) when it has none left.
    bool advance() @safe pure nothrow
    {
        auto cp = &stack[$ - 1];
        if (cp.cur == cp.end)
        {
            chosen[cp.pkg] = nil;
            stack.length = stack.length - 1;
            return false;
        }
        chosen[cp.pkg] = cp.cur;
        immutable slot = ix.verStart[cp.pkg] + cp.cur;
        ++cp.cur;
        arenaLen = cp.arenaTop;
        pending = cp.rest;
        pushRange(ix.reqStart[slot], ix.reqStart[slot + 1]);
        return true;
    }

    ulong choicePoints = 0;
    bool failed = false;
    for (;;)
    {
        if (!failed)
        {
            if (pending == nil)
                break; // success
            immutable node = arena[pending];
            immutable r = ix.reqs[node.req];
            immutable c = chosen[r.pkg];
            if (c != nil)
            {
                if (c >= r.from && c < r.to)
                    pending = node.next;
                else
                    failed = true;
            }
            else if (r.from < r.to)
            {
                ++choicePoints;
                stack ~= Choice(r.pkg, r.from, r.to, node.next, cast(uint) arenaLen);
                advance(); // cannot fail: the candidate range is non-empty
            }
            else
                failed = true;
            continue;
        }

        // Backtrack to the most recent choice point with an untried candidate.
        while (stack.length && !advance()) {}
        if (stack.length == 0)
            return Resolution(false, null, choicePoints);
        failed = false;
    }

    Resolution res;
    res.success = true;
    res.choicePoints = choicePoints;
    foreach (p; 0 .. P)
        if (chosen[p] != nil)
            res.picks ~= Pick(ix.names[p], ix.versions[ix.verStart[p] + chosen[p]]);
    res.picks.sort!((a, b) => a.name < b.name);
    return res;
}

version (unittest)
{
    import depresolve.parser : parseProblem;

    private string run(string text) @safe
    {
        import depresolve.output : formatResolution;
        auto p = parseProblem(text);
        return formatResolution(resolve(p.registry, p.root));
    }

    /// Direct transcription of the specification's recursive search.
    private Pick[] referenceResolve(const Registry reg, const Dependency[] root, out bool ok) @safe
    {
        alias Chosen = Version[string];
        struct Out { bool ok; Chosen chosen; }

        Out go(const(Dependency)[] pending, Chosen chosen) @safe
        {
            if (pending.length == 0) return Out(true, chosen);
            auto head = pending[0];
            auto rest = pending[1 .. $];
            if (auto c = head.name in chosen)
            {
                if (head.range.contains(*c)) return go(rest, chosen);
                return Out(false, null);
            }
            PackageVersion[] cands;
            foreach (ref e; reg.entries)
                if (e.name == head.name && head.range.contains(e.version_))
                    cands ~= PackageVersion(e.name, e.version_, e.dependencies.dup);
            cands.sort!((a, b) => a.version_ > b.version_);
            foreach (c; cands)
            {
                auto next = chosen.dup;
                next[head.name] = c.version_;
                auto r = go(c.dependencies ~ rest, next);
                if (r.ok) return r;
            }
            return Out(false, null);
        }

        auto r = go(root, null);
        ok = r.ok;
        Pick[] picks;
        foreach (k, v; r.chosen) picks ~= Pick(k, v);
        picks.sort!((a, b) => a.name < b.name);
        return picks;
    }

    // Deterministic xorshift, so failures are reproducible.
    private struct Rng
    {
        ulong s;
        uint next() @safe pure nothrow @nogc
        {
            s ^= s << 13; s ^= s >> 7; s ^= s << 17;
            return cast(uint) (s >> 11);
        }
        uint below(uint n) @safe pure nothrow @nogc { return next() % n; }
    }
}

// Specification example 1: a diamond that needs backtracking.
@safe unittest
{
    assert(run(
        "a 1.0.0: c ^1.0.0\n" ~
        "b 1.0.0: c ~1.2.0\n" ~
        "c 1.1.0:\n" ~
        "c 1.2.5:\n" ~
        "c 1.3.0:\n" ~
        "root: a *, b *\n") == "a 1.0.0\nb 1.0.0\nc 1.2.5\n");
}

// Example 2: the first solution found, not the globally newest set.
@safe unittest
{
    assert(run(
        "a 2.0.0: b ~1.0.0\n" ~
        "a 1.0.0:\n" ~
        "b 1.0.0:\n" ~
        "b 1.0.5:\n" ~
        "b 1.5.0:\n" ~
        "b 2.0.0:\n" ~
        "root: a *, b *\n") == "a 2.0.0\nb 1.0.5\n");
}

// Example 3: conflicting majors.
@safe unittest
{
    assert(run(
        "a 1.0.0: c ^1.0.0\n" ~
        "b 1.0.0: c ^2.0.0\n" ~
        "c 1.0.0:\n" ~
        "c 2.0.0:\n" ~
        "root: a *, b *\n") == "unsatisfiable\n");
}

// Example 4: the order of root requirements matters.
@safe unittest
{
    enum reg =
        "a 2.0.0: c ^2.0.0\n" ~
        "a 1.0.0: c ^1.0.0\n" ~
        "b 2.0.0: c ^1.0.0\n" ~
        "b 1.0.0: c ^2.0.0\n" ~
        "c 1.0.0:\n" ~
        "c 2.0.0:\n";
    assert(run(reg ~ "root: a *, b *\n") == "a 2.0.0\nb 1.0.0\nc 2.0.0\n");
    assert(run(reg ~ "root: b *, a *\n") == "a 1.0.0\nb 2.0.0\nc 1.0.0\n");
}

@safe unittest
{
    // Empty root and empty registry.
    assert(run("root:\n") == "");
    assert(run("a 1.0.0:\nroot:\n") == "");
    // Requirement on an absent package.
    assert(run("root: ghost *\n") == "unsatisfiable\n");
    // Empty range.
    assert(run("a 1.0.0:\nroot: a >=2.0.0 <1.0.0\n") == "unsatisfiable\n");
    // Numeric version ordering and name ordering.
    assert(run("a 1.9.0:\na 1.10.0:\nroot: a *\n") == "a 1.10.0\n");
    assert(run("mylib 1.0.0:\nmy-lib2 1.0.0:\nmy-lib 1.0.0:\nroot: mylib *, my-lib2 *, my-lib *\n")
        == "my-lib 1.0.0\nmy-lib2 1.0.0\nmylib 1.0.0\n");
}

@safe unittest
{
    // Cycles, including a version requiring its own package.
    assert(run(
        "a 1.0.0: b *\n" ~
        "b 1.0.0: a ^1.0.0\n" ~
        "root: a *\n") == "a 1.0.0\nb 1.0.0\n");
    assert(run(
        "a 2.0.0: a ^1.0.0\n" ~
        "a 1.0.0:\n" ~
        "root: a *\n") == "a 1.0.0\n");
}

@safe unittest
{
    // Backtracking is chronological: an unrelated later package is retried
    // before the culprit, which yields the specified (not the minimal) answer.
    assert(run(
        "a 2.0.0:\n" ~
        "a 1.0.0:\n" ~
        "b 2.0.0: z 1.0.0\n" ~
        "b 1.0.0:\n" ~
        "z 1.0.0:\n" ~
        "root: a *, b *\n") == "a 2.0.0\nb 2.0.0\nz 1.0.0\n");
    // Requirements of unchosen versions are irrelevant.
    assert(run(
        "a 2.0.0: nothere *\n" ~
        "a 1.0.0:\n" ~
        "root: a *\n") == "a 1.0.0\n");
}

// A 3000-package chain whose tail forces a retry; exercises recursion depth.
@safe unittest
{
    import std.array : appender;
    import std.format : formattedWrite;
    auto text = appender!string;
    enum n = 3000;
    foreach (i; 0 .. n)
    {
        if (i + 1 < n)
            text.formattedWrite("p%s 2.0.0: p%s *\n", i, i + 1);
        else
            text.formattedWrite("p%s 2.0.0: missing *\n", i);
        text.formattedWrite("p%s 1.0.0:\n", i);
    }
    text.put("root: p0 *\n");
    auto out_ = run(text.data);
    // The tail p2999 falls back to 1.0.0; everything before it stays at 2.0.0.
    import std.algorithm : count;
    import std.string : lineSplitter;
    assert(out_.lineSplitter.count == n);
    assert(out_.lineSplitter.count!(l => l.length > 6 && l[$ - 5 .. $] == "1.0.0") == 1);
}

// Cross-check against the literal recursive transcription on random registries.
@safe unittest
{
    import std.format : format;
    auto rng = Rng(0x9E3779B97F4A7C15);
    static immutable rangeKinds = ["*", "^1.0.0", "~1.1.0", "^0.1.0", "^0.0.2", "1.0.0",
                                   ">=1.0.0 <2.0.0", ">1.0.0", "<=1.1.0", ">=2.0.0 <1.0.0", "~0.0.2"];
    foreach (iter; 0 .. 400)
    {
        immutable nPk = 2 + rng.below(6);
        Registry reg;
        Dependency[] mkDeps(uint maxN) @safe
        {
            Dependency[] deps;
            bool[uint] used;
            foreach (_; 0 .. rng.below(maxN + 1))
            {
                immutable t = rng.below(nPk + 1); // nPk -> package with no versions
                if (t in used) continue;
                used[t] = true;
                deps ~= Dependency(format("p%s", t),
                    VersionRange.parse(rangeKinds[rng.below(cast(uint) rangeKinds.length)]));
            }
            return deps;
        }
        foreach (p; 0 .. nPk)
        {
            bool[Version] seen;
            foreach (_; 0 .. rng.below(5))
            {
                auto v = Version(rng.below(3), rng.below(3), rng.below(3));
                if (v in seen) continue;
                seen[v] = true;
                reg.add(format("p%s", p), v, mkDeps(3));
            }
        }
        auto root = mkDeps(4);
        bool ok;
        auto expected = referenceResolve(reg, root, ok);
        auto got = resolve(reg, root);
        assert(got.success == ok, format("iteration %s", iter));
        if (ok) assert(got.picks == expected, format("iteration %s", iter));
    }
}
