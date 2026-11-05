/**
 * The search engine: ties parsing, matching, scoring, ranking and snippets
 * together.
 */
module fulltext.search;

import fulltext.index;
import fulltext.matcher;
import fulltext.query;
import fulltext.ranking;
import fulltext.snippet;

/// One ranked hit.
struct SearchResult
{
    /// The document id.
    string docId;
    /// BM25 score.
    double score;
    /// Snippet text (whitespace collapsed; may be empty).
    string snippet;
}

/// Evaluates queries against an `Index`.
final class SearchEngine
{
    private const(Index) index;

    /// Creates an engine over `index`, which must outlive it.
    this(const Index index)
    {
        this.index = index;
    }

    /// Parses `query` and returns at most `k` ranked results.
    SearchResult[] search(string query, size_t k)
    {
        return search(parseQuery(query), k);
    }

    /// Evaluates an already parsed query tree (`null` is the empty tree).
    SearchResult[] search(const Node tree, size_t k)
    {
        auto cache = OccurrenceCache(index);
        auto matched = evaluate(tree, cache, index.docCount);
        auto atoms = positiveAtoms(tree);

        // Occurrences per positive atom (copied: the cache returns refs).
        Occurrences[] occ;
        double[] idfs;
        foreach (a; atoms)
        {
            occ ~= cache.get(a);
            idfs ~= idf(index.docCount, occ[$ - 1].df);
        }

        auto cursors = new size_t[atoms.length];
        ScoredDoc[] scored;
        immutable avgdl = index.avgDocLength;
        matched.each((uint d) {
            double score = 0;
            foreach (i, ref o; occ)
            {
                auto at = lowerBound(o.docs, d, cursors[i]);
                cursors[i] = at;
                if (at < o.docs.length && o.docs[at] == d)
                {
                    immutable f = o.offsets[at + 1] - o.offsets[at];
                    score += termScore(idfs[i], f, index.docLength(d), avgdl);
                }
            }
            scored ~= ScoredDoc(d, score);
        });

        SearchResult[] results;
        foreach (sd; topK(scored, k))
        {
            AtomHits[] hits;
            foreach (i, ref o; occ)
            {
                immutable at = o.find(sd.doc);
                if (at != size_t.max)
                    hits ~= AtomHits(cast(uint) atoms[i].terms.length, o.startsAt(at));
            }
            immutable start = bestWindowStart(index.docLength(sd.doc), hits);
            results ~= SearchResult(index.docId(sd.doc), sd.score,
                    snippetText(index.docText(sd.doc), index.tokenStarts(sd.doc),
                        index.tokenEnds(sd.doc), start));
        }
        return results;
    }
}
