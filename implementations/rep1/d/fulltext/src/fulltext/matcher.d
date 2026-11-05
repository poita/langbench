/**
 * Boolean and phrase matching: atom occurrences, document sets and tree
 * evaluation.
 */
module fulltext.matcher;

import core.bitop : bsf;
import std.array : appender;

import fulltext.index;
import fulltext.query;

/**
 * Where an atom occurs: ascending `docs`, and for the i-th of them the
 * ascending start positions `positions[offsets[i] .. offsets[i + 1]]`.
 * `offsets` is empty when the atom occurs nowhere.
 */
struct Occurrences
{
    const(uint)[] docs;
    const(uint)[] offsets;
    const(uint)[] positions;

    /// Document frequency of the atom.
    size_t df() const pure nothrow @nogc @safe
    {
        return docs.length;
    }

    /// Start positions in the i-th document of `docs`.
    const(uint)[] startsAt(size_t i) const pure nothrow @nogc @safe
    {
        return positions[offsets[i] .. offsets[i + 1]];
    }

    /// Index into `docs` of document `doc`, or `size_t.max` if absent.
    size_t find(uint doc) const pure nothrow @nogc @safe
    {
        immutable i = lowerBound(docs, doc, 0);
        return (i < docs.length && docs[i] == doc) ? i : size_t.max;
    }
}

/// First index `i >= from` with `a[i] >= value` (or `a.length`).
size_t lowerBound(const(uint)[] a, uint value, size_t from) pure nothrow @nogc @safe
{
    size_t lo = from, hi = a.length;
    while (lo < hi)
    {
        immutable mid = lo + (hi - lo) / 2;
        if (a[mid] < value)
            lo = mid + 1;
        else
            hi = mid;
    }
    return lo;
}

/**
 * Computes the occurrences of the atom made of `terms` (all of which must
 * be non-empty): a single term uses its postings directly; longer atoms
 * are matched positionally.
 */
Occurrences findOccurrences(const Index index, const(string)[] terms)
{
    assert(terms.length > 0);
    const(Postings)*[] ps;
    foreach (t; terms)
    {
        immutable id = index.lookupTerm(t);
        if (id == noTerm)
            return Occurrences.init;
        ps ~= &index.postings(id);
    }
    if (ps.length == 1)
        return Occurrences(ps[0].docs, ps[0].offsets, ps[0].positions);

    size_t rarest = 0;
    foreach (i, p; ps)
        if (p.docs.length < ps[rarest].docs.length)
            rarest = i;

    auto cursors = new size_t[ps.length];
    auto locs = new size_t[ps.length];
    auto outDocs = appender!(uint[]);
    auto outOffsets = appender!(uint[]);
    auto outPositions = appender!(uint[]);
    auto cur = appender!(uint[]);

    foreach (di, doc; ps[rarest].docs)
    {
        bool ok = true;
        foreach (i, p; ps)
        {
            if (i == rarest)
            {
                locs[i] = di;
                continue;
            }
            immutable at = lowerBound(p.docs, doc, cursors[i]);
            cursors[i] = at;
            if (at >= p.docs.length || p.docs[at] != doc)
            {
                ok = false;
                break;
            }
            locs[i] = at;
        }
        if (!ok)
            continue;

        cur.clear();
        cur.put(ps[0].positionsAt(locs[0]));
        auto buf = cur.data;
        size_t n = buf.length;
        foreach (i; 1 .. ps.length)
        {
            auto other = ps[i].positionsAt(locs[i]);
            size_t j = 0, w = 0;
            foreach (r; 0 .. n)
            {
                immutable want = buf[r] + cast(uint) i;
                while (j < other.length && other[j] < want)
                    ++j;
                if (j == other.length)
                    break;
                if (other[j] == want)
                    buf[w++] = buf[r];
            }
            n = w;
            if (n == 0)
                break;
        }
        if (n > 0)
        {
            outDocs.put(doc);
            outOffsets.put(cast(uint) outPositions.data.length);
            outPositions.put(buf[0 .. n]);
        }
    }
    if (outDocs.data.length == 0)
        return Occurrences.init;
    outOffsets.put(cast(uint) outPositions.data.length);
    return Occurrences(outDocs.data, outOffsets.data, outPositions.data);
}

/// A set of document numbers drawn from `0 .. N-1`, stored as a bitset.
struct DocSet
{
    private ulong[] words;
    private size_t n;

    /// The empty set over `n` documents.
    static DocSet empty(size_t n) pure nothrow @safe
    {
        DocSet s;
        s.n = n;
        s.words = new ulong[(n + 63) / 64];
        return s;
    }

    /// Adds document `d`.
    void add(size_t d) pure nothrow @nogc @safe
    {
        words[d >> 6] |= 1UL << (d & 63);
    }

    /// Is `d` a member?
    bool contains(size_t d) const pure nothrow @nogc @safe
    {
        return (words[d >> 6] >> (d & 63)) & 1;
    }

    /// Number of members.
    size_t count() const pure nothrow @nogc @safe
    {
        import core.bitop : popcnt;

        size_t c = 0;
        foreach (w; words)
            c += popcnt(w);
        return c;
    }

    /// The complement within `0 .. N-1`.
    DocSet complement() const pure nothrow @safe
    {
        auto r = DocSet.empty(n);
        foreach (i, w; words)
            r.words[i] = ~w;
        if (n % 64 != 0)
            r.words[$ - 1] &= (1UL << (n % 64)) - 1;
        return r;
    }

    /// Intersects `other` into this set.
    void intersect(const DocSet other) pure nothrow @nogc @safe
    {
        foreach (i, ref w; words)
            w &= other.words[i];
    }

    /// Unites `other` into this set.
    void unite(const DocSet other) pure nothrow @nogc @safe
    {
        foreach (i, ref w; words)
            w |= other.words[i];
    }

    /// Calls `dg` with every member in ascending order.
    void each(scope void delegate(uint) dg) const
    {
        foreach (i, w0; words)
        {
            ulong w = w0;
            while (w)
            {
                immutable b = bsf(w);
                dg(cast(uint)(i * 64 + b));
                w &= w - 1;
            }
        }
    }
}

/// Per-query cache of atom occurrences, keyed by `Atom.key`.
struct OccurrenceCache
{
    private Occurrences[string] map;
    private const(Index) index;

    this(const Index index)
    {
        this.index = index;
    }

    /// The occurrences of `a`, computed on first use.
    ref const(Occurrences) get(const Atom a)
    {
        auto k = a.key;
        if (auto p = k in map)
            return *p;
        map[k] = findOccurrences(index, a.terms);
        return map[k];
    }
}

/// Evaluates a query tree to the set of matching documents. The empty
/// tree (`null`) matches nothing.
DocSet evaluate(const Node root, ref OccurrenceCache cache, size_t docCount)
{
    DocSet eval(const Node n)
    {
        final switch (n.kind)
        {
        case NodeKind.atom:
            auto s = DocSet.empty(docCount);
            foreach (d; cache.get(n.atom).docs)
                s.add(d);
            return s;
        case NodeKind.not:
            return eval(n.children[0]).complement();
        case NodeKind.and:
            auto s = eval(n.children[0]);
            foreach (c; n.children[1 .. $])
                s.intersect(eval(c));
            return s;
        case NodeKind.or:
            auto s = eval(n.children[0]);
            foreach (c; n.children[1 .. $])
                s.unite(eval(c));
            return s;
        }
    }

    if (root is null)
        return DocSet.empty(docCount);
    return eval(root);
}
