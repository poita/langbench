/**
 * Formatting of `results.txt` and `stats.txt`.
 */
module fulltext.report;

import std.array : appender;
import std.format : formattedWrite;

import fulltext.index : Index;
import fulltext.search : SearchResult;

/// Appends one `QUERY`/`HITS` block to `sink`.
void formatQueryBlock(Sink)(ref Sink sink, uint number, string queryText, const SearchResult[] results)
{
    formattedWrite(sink, "QUERY %d %s\nHITS %d\n", number, queryText, results.length);
    foreach (i, ref r; results)
        formattedWrite(sink, "%d\t%s\t%.4f\t%s\n", i + 1, r.docId, r.score, r.snippet);
}

/// Renders the contents of `stats.txt` for `index`.
string formatStats(const Index index)
{
    auto app = appender!string;
    formattedWrite(app, "documents %d\ntokens %d\nterms %d\navgdl %.4f\n",
            index.docCount, index.totalTokens, index.termCount, index.avgDocLength);
    return app.data;
}
