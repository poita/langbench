/**
 * BM25 scoring and top-k selection.
 */
module fulltext.ranking;

import std.algorithm.sorting : partialSort, sort;
import std.math : log;

/// BM25 free parameter `k1`.
enum double bm25K1 = 1.2;
/// BM25 free parameter `b`.
enum double bm25B = 0.75;

/// Inverse document frequency of an atom with document frequency `df` in a
/// corpus of `docCount` documents.
double idf(size_t docCount, size_t df) pure nothrow @nogc @safe
{
    return log((cast(double) docCount - df + 0.5) / (df + 0.5) + 1.0);
}

/**
 * The BM25 contribution of one atom occurring `freq` times in a document of
 * length `docLen`, given the corpus mean length `avgdl` and the atom's `idf`.
 */
double termScore(double idfValue, double freq, double docLen, double avgdl) pure nothrow @nogc @safe
{
    immutable ratio = avgdl == 0 ? 0.0 : docLen / avgdl;
    return idfValue * (freq * (bm25K1 + 1)) / (freq + bm25K1 * (1 - bm25B + bm25B * ratio));
}

/// A document number with its score.
struct ScoredDoc
{
    uint doc;
    double score;
}

/// Ordering: higher score first, ties by smaller document number.
bool ranksBefore(const ScoredDoc a, const ScoredDoc b) pure nothrow @nogc @safe
{
    if (a.score != b.score)
        return a.score > b.score;
    return a.doc < b.doc;
}

/// Sorts `docs` by rank and returns the first `k` of them.
ScoredDoc[] topK(ScoredDoc[] docs, size_t k) pure nothrow @trusted
{
    if (k >= docs.length)
    {
        docs.sort!ranksBefore;
        return docs;
    }
    docs.partialSort!ranksBefore(k);
    return docs[0 .. k];
}
