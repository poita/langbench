/**
 * Query evaluation: phrase matching, boolean set algebra, BM25 scoring and
 * ranking.
 */
module fulltext.search;

import std.algorithm : sort;
import std.math : log;

import fulltext.index;
import fulltext.query;
import fulltext.snippet;

@safe:

/// BM25 parameters.
enum double bm25K1 = 1.2;
/// ditto
enum double bm25B = 0.75;

/// A ranked result.
struct Hit
{
    /// Document number in the index.
    uint doc;
    /// Document identifier.
    string id;
    /// BM25 score.
    double score;
    /// Best-window snippet of the document text.
    string snippet;
}

/// First index `i >= from` with `a[i] >= v` (galloping search).
private size_t lowerBoundFrom(const(uint)[] a, size_t from, uint v) pure nothrow @nogc
{
    size_t lo = from, step = 1;
    while (lo + step < a.length && a[lo + step] < v)
    {
        lo += step;
        step <<= 1;
    }
    size_t hi = lo + step < a.length ? lo + step : a.length;
    while (lo < hi)
    {
        immutable mid = lo + (hi - lo) / 2;
        if (a[mid] < v)
            lo = mid + 1;
        else
            hi = mid;
    }
    return lo;
}

/**
 * Intersects the postings of an atom's terms: position `p` of the result is
 * where term `i` occurs at `p + i` for every `i`. Occurrences may overlap.
 * Linear in the lengths of the lists involved (document lists are skipped
 * with galloping search).
 */
Occurrences phraseOccurrences(const(Occurrences)[] lists) pure nothrow
{
    if (lists.length == 1)
        return lists[0];
    uint[] outDocs, outStarts, outPos;
    immutable n = lists.length;

    // Drive by the term with the fewest documents.
    size_t driver = 0;
    foreach (j, ref l; lists)
        if (l.length < lists[driver].length)
            driver = j;

    auto cursor = new size_t[n];
    auto idx = new size_t[n];
    uint[] cur;

    docLoop:
    foreach (i; 0 .. lists[driver].length)
    {
        immutable d = lists[driver].docs[i];
        idx[driver] = i;
        foreach (j; 0 .. n)
        {
            if (j == driver)
                continue;
            immutable at = lowerBoundFrom(lists[j].docs, cursor[j], d);
            cursor[j] = at;
            if (at == lists[j].length)
                break docLoop;
            if (lists[j].docs[at] != d)
                continue docLoop;
            idx[j] = at;
        }
        cur = lists[0].positionsAt(idx[0]).dup;
        foreach (j; 1 .. n)
        {
            auto pj = lists[j].positionsAt(idx[j]);
            size_t q = 0, w = 0;
            foreach (p; cur)
            {
                immutable target = p + cast(uint) j;
                while (q < pj.length && pj[q] < target)
                    q++;
                if (q == pj.length)
                    break;
                if (pj[q] == target)
                    cur[w++] = p;
            }
            cur = cur[0 .. w];
            if (w == 0)
                break;
        }
        if (cur.length)
        {
            outDocs ~= d;
            outStarts ~= cast(uint) outPos.length;
            outPos ~= cur;
        }
    }
    return Occurrences(outDocs, outStarts, outPos);
}

/// Occurrences of `atom` in the index.
Occurrences matchAtom(const Index index, const Atom atom)
{
    auto lists = new Occurrences[atom.length];
    foreach (i, t; atom.terms)
    {
        lists[i] = index.lookup(t);
        if (lists[i].empty)
            return Occurrences.init;
    }
    return phraseOccurrences(lists);
}

/// Evaluates queries against an $(LREF Index).
final class Searcher
{
    private const Index index_;

    this(const Index index) pure nothrow @nogc
    {
        index_ = index;
    }

    /// The index being searched.
    @property const(Index) index() const pure nothrow @nogc { return index_; }

    /**
     * Parses and runs `queryText`, returning the top `k` hits, best first.
     * Ties on score are broken by document id.
     */
    Hit[] search(string queryText, size_t k) const
    {
        return search(parseQuery(queryText), k);
    }

    /// Runs an already-parsed query tree.
    Hit[] search(const Node tree, size_t k) const
    {
        if (tree is null || index_.documentCount == 0)
            return null;

        Occurrences[string] cache;
        Occurrences occurrences(const Atom a)
        {
            immutable key = a.key;
            if (auto p = key in cache)
                return *p;
            auto m = matchAtom(index_, a);
            cache[key] = m;
            return m;
        }

        immutable n = index_.documentCount;

        bool[] eval(const Node node)
        {
            final switch (node.kind)
            {
                case NodeKind.atom:
                    auto flags = new bool[n];
                    foreach (d; occurrences(node.atom).docs)
                        flags[d] = true;
                    return flags;
                case NodeKind.not:
                    auto flags = eval(node.children[0]);
                    foreach (ref f; flags)
                        f = !f;
                    return flags;
                case NodeKind.and:
                    auto flags = eval(node.children[0]);
                    foreach (c; node.children[1 .. $])
                    {
                        auto o = eval(c);
                        foreach (i; 0 .. n)
                            flags[i] = flags[i] && o[i];
                    }
                    return flags;
                case NodeKind.or:
                    auto flags = eval(node.children[0]);
                    foreach (c; node.children[1 .. $])
                    {
                        auto o = eval(c);
                        foreach (i; 0 .. n)
                            flags[i] = flags[i] || o[i];
                    }
                    return flags;
            }
        }

        auto matched = eval(tree);

        // Positive atoms and their statistics.
        auto atoms = positiveAtoms(tree);
        auto occ = new Occurrences[atoms.length];
        auto idf = new double[atoms.length];
        foreach (i, ref a; atoms)
        {
            occ[i] = occurrences(a);
            immutable df = cast(double) occ[i].length;
            idf[i] = log((n - df + 0.5) / (df + 0.5) + 1.0);
        }

        immutable avgdl = index_.averageLength;

        static struct Scored
        {
            uint doc;
            double score;
        }

        Scored[] candidates;
        foreach (uint d; 0 .. cast(uint) n)
        {
            if (!matched[d])
                continue;
            immutable ratio = avgdl == 0 ? 0.0 : index_.length(d) / avgdl;
            immutable norm = bm25K1 * (1 - bm25B + bm25B * ratio);
            double score = 0;
            foreach (i; 0 .. atoms.length)
            {
                immutable at = occ[i].find(d);
                if (at == size_t.max)
                    continue;
                immutable f = cast(double) occ[i].positionsAt(at).length;
                score += idf[i] * (f * (bm25K1 + 1) / (f + norm));
            }
            candidates ~= Scored(d, score);
        }

        candidates.sort!((a, b) => a.score > b.score
            || (a.score == b.score && index_.id(a.doc) < index_.id(b.doc)));
        if (candidates.length > k)
            candidates = candidates[0 .. k];

        Hit[] hits;
        hits.reserve(candidates.length);
        foreach (c; candidates)
        {
            AtomHits[] ah;
            foreach (i, ref a; atoms)
            {
                immutable at = occ[i].find(c.doc);
                if (at != size_t.max)
                    ah ~= AtomHits(cast(uint) a.length, occ[i].positionsAt(at));
            }
            hits ~= Hit(c.doc, index_.id(c.doc), c.score,
                makeSnippet(index_.text(c.doc), index_.length(c.doc), ah));
        }
        return hits;
    }
}

version (unittest)
{
    private Index sample()
    {
        return Index.build([
            Document("copy1", "alpha beta gamma"),
            Document("copy2", "alpha beta gamma"),
            Document("copy3", "alpha beta gamma"),
            Document("other", "alpha alpha beta"),
        ]);
    }

    private string[] ids(const Hit[] hits)
    {
        string[] r;
        foreach (h; hits)
            r ~= h.id;
        return r;
    }
}

unittest
{
    auto s = new Searcher(sample());
    auto hits = s.search("alpha", 10);
    assert(ids(hits) == ["other", "copy1", "copy2", "copy3"]);
    assert(hits[0].snippet == "alpha alpha beta");
    import std.format : format;
    assert(format("%.4f", hits[0].score) == "0.1449");
    assert(format("%.4f", hits[1].score) == "0.1054");
    assert(ids(s.search("alpha", 2)) == ["other", "copy1"]);
}

unittest
{
    auto s = new Searcher(sample());
    assert(ids(s.search("gamma OR alpha alpha", 10)).length == 4);
    assert(ids(s.search("NOT gamma", 10)) == ["other"]);
    assert(ids(s.search("alpha AND NOT alpha", 10)).length == 0);
    assert(ids(s.search("\"alpha alpha\"", 10)) == ["other"]);
    assert(ids(s.search("\"beta alpha\"", 10)).length == 0);
    assert(ids(s.search("the", 10)).length == 0);   // empty tree matches nothing
    assert(ids(s.search("", 10)).length == 0);
    assert(ids(s.search("unknownword", 10)).length == 0);
    // negation only: matched, score 0
    auto h = s.search("NOT unknownword", 10);
    assert(h.length == 4 && h[0].score == 0 && h[0].id == "copy1");
}

unittest
{
    // overlapping phrase occurrences
    auto ix = Index.build([Document("d", "aa aa aa aa")]);
    auto m = matchAtom(ix, Atom(["aa", "aa"]));
    assert(m.docs == [0]);
    assert(m.positionsAt(0) == [0, 1, 2]);
    auto m3 = matchAtom(ix, Atom(["aa", "aa", "aa"]));
    assert(m3.positionsAt(0) == [0, 1]);
}

unittest
{
    // stop words take part in phrases
    auto ix = Index.build([Document("d", "to be or not to be, that"),
        Document("e", "be to")]);
    auto s = new Searcher(ix);
    assert(ids(s.search("\"to be or not to be\"", 5)) == ["d"]);
    assert(ids(s.search("\"be or\"", 5)) == ["d"]);
}

unittest
{
    // empty corpus and empty documents
    auto s = new Searcher(Index.build([]));
    assert(s.search("x", 10).length == 0);
    auto s2 = new Searcher(Index.build([Document("e", "")]));
    auto h = s2.search("NOT x", 10);
    assert(h.length == 1 && h[0].score == 0 && h[0].snippet == "");
}

unittest
{
    // galloping search
    uint[] a = [1, 3, 5, 7, 9, 11, 13];
    assert(lowerBoundFrom(a, 0, 0) == 0);
    assert(lowerBoundFrom(a, 0, 6) == 3);
    assert(lowerBoundFrom(a, 2, 13) == 6);
    assert(lowerBoundFrom(a, 0, 14) == 7);
    assert(lowerBoundFrom(a, 7, 1) == 7);
}
