/**
 * Rendering of `results.txt` and `stats.txt`.
 */
module fulltext.report;

import std.array : Appender;
import std.format : formattedWrite;

import fulltext.index;
import fulltext.queryfile;
import fulltext.search;

@safe:

/// Appends the result block of one query to `sink`.
void formatBlock(ref Appender!string sink, const QueryLine q, const Hit[] hits)
{
    sink.formattedWrite("QUERY %d %s\nHITS %d\n", q.number, q.text, hits.length);
    foreach (rank, h; hits)
        sink.formattedWrite("%d\t%s\t%.4f\t%s\n", rank + 1, h.id, h.score, h.snippet);
}

/// Runs every query and returns the text of `results.txt`.
string renderResults(const Searcher searcher, const QueryLine[] queries)
{
    Appender!string sink;
    foreach (ref q; queries)
        formatBlock(sink, q, searcher.search(q.text, q.k));
    return sink.data;
}

/// The text of `stats.txt` for an index.
string renderStats(const Index index)
{
    Appender!string sink;
    sink.formattedWrite("documents %d\ntokens %d\nterms %d\navgdl %.4f\n",
        index.documentCount, index.tokenCount, index.termCount, index.averageLength);
    return sink.data;
}

unittest
{
    auto ix = Index.build([Document("note", "The quick brown fox jumps over the lazy dog.")]);
    assert(renderStats(ix) == "documents 1\ntokens 9\nterms 8\navgdl 9.0000\n");

    auto qs = parseQueryFile("fox\nquick brown\ncat\n\"lazy dog\"\n");
    immutable expected =
        "QUERY 1 fox\nHITS 1\n1\tnote\t0.2877\tThe quick brown fox jumps over the lazy dog\n"
        ~ "QUERY 2 quick brown\nHITS 1\n1\tnote\t0.5754\tThe quick brown fox jumps over the lazy dog\n"
        ~ "QUERY 3 cat\nHITS 0\n"
        ~ "QUERY 4 \"lazy dog\"\nHITS 1\n1\tnote\t0.2877\tThe quick brown fox jumps over the lazy dog\n";
    assert(renderResults(new Searcher(ix), qs) == expected);
}

unittest
{
    assert(renderStats(Index.build([])) == "documents 0\ntokens 0\nterms 0\navgdl 0.0000\n");
    // empty snippet ends the line with the third tab
    auto ix = Index.build([Document("e", "")]);
    auto qs = parseQueryFile("NOT x");
    assert(renderResults(new Searcher(ix), qs) == "QUERY 1 NOT x\nHITS 1\n1\te\t0.0000\t\n");
}
