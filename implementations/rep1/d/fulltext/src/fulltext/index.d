/**
 * The positional inverted index.
 *
 * Documents are numbered `0 .. N-1` in ascending order of their ids, so that
 * document-number order is id order. Every term has a dense integer id and a
 * `Postings` record holding, for each containing document, the ascending
 * token positions of the term.
 */
module fulltext.index;

import std.algorithm.sorting : sort;
import std.array : appender;

import fulltext.analysis : Span, TermAnalyzer, Tokenizer;

/// A document to be indexed: an id and its UTF-8 text.
struct Document
{
    /// Unique document id (ordered by code point / UTF-8 byte order).
    string id;
    /// The document text exactly as read; never transformed.
    immutable(ubyte)[] text;

    /// Convenience constructor from a `string`.
    static Document fromString(string id, string text) pure nothrow @trusted
    {
        return Document(id, cast(immutable(ubyte)[]) text);
    }
}

/// Marker returned by `Index.lookupTerm` for a term that is not indexed.
enum uint noTerm = uint.max;

/**
 * Postings of one term, stored in flat arrays.
 *
 * `docs[i]` is the i-th containing document (ascending); its positions are
 * `positions[offsets[i] .. offsets[i + 1]]` (ascending). `offsets` has
 * `docs.length + 1` entries.
 */
struct Postings
{
    uint[] docs;
    uint[] offsets;
    uint[] positions;

    /// Number of documents containing the term.
    size_t df() const pure nothrow @nogc @safe
    {
        return docs.length;
    }

    /// The positions of the term in the `i`-th document of `docs`.
    const(uint)[] positionsAt(size_t i) const pure nothrow @nogc @safe
    {
        return positions[offsets[i] .. offsets[i + 1]];
    }
}

/// An immutable, fully built index over a set of documents.
final class Index
{
    private string[] _ids;
    private immutable(ubyte)[][] _texts;
    private uint[][] _starts;
    private uint[][] _ends;
    private Postings[] _postings;
    private uint[string] _termIds;
    private size_t _totalTokens;

    /**
     * Builds an index. Documents may be given in any order; they are sorted
     * by id. Ids must be unique.
     */
    this(Document[] docs)
    {
        docs.sort!((a, b) => a.id < b.id);
        immutable n = docs.length;
        _ids = new string[n];
        _texts = new immutable(ubyte)[][n];
        _starts = new uint[][n];
        _ends = new uint[][n];

        TermAnalyzer analyzer;
        uint[string] rawMemo; // raw token bytes -> term id

        foreach (d, ref doc; docs)
        {
            _ids[d] = doc.id;
            _texts[d] = doc.text;
            auto starts = appender!(uint[]);
            auto ends = appender!(uint[]);
            uint pos = 0;
            foreach (span; Tokenizer(doc.text))
            {
                auto raw = doc.text[span.start .. span.end];
                uint tid;
                if (auto p = (() @trusted => cast(string) raw)() in rawMemo)
                    tid = *p;
                else
                {
                    bool stop;
                    auto term = analyzer.analyze(raw, stop);
                    if (auto q = (() @trusted => cast(string) term)() in _termIds)
                        tid = *q;
                    else
                    {
                        tid = cast(uint) _postings.length;
                        _termIds[term.idup] = tid;
                        _postings.length = _postings.length + 1;
                    }
                    rawMemo[(() @trusted => cast(string) raw.idup)()] = tid;
                }
                auto post = &_postings[tid];
                if (post.docs.length == 0 || post.docs[$ - 1] != d)
                {
                    post.docs ~= cast(uint) d;
                    post.offsets ~= cast(uint) post.positions.length;
                }
                post.positions ~= pos;
                starts.put(span.start);
                ends.put(span.end);
                ++pos;
            }
            _starts[d] = starts.data;
            _ends[d] = ends.data;
            _totalTokens += pos;
        }
        foreach (ref p; _postings)
            p.offsets ~= cast(uint) p.positions.length;
    }

    /// Number of documents, `N`.
    @property size_t docCount() const pure nothrow @nogc @safe
    {
        return _ids.length;
    }

    /// Total number of tokens over all documents.
    @property size_t totalTokens() const pure nothrow @nogc @safe
    {
        return _totalTokens;
    }

    /// Number of distinct terms.
    @property size_t termCount() const pure nothrow @nogc @safe
    {
        return _postings.length;
    }

    /// Mean document length; 0 when there are no documents.
    @property double avgDocLength() const pure nothrow @nogc @safe
    {
        return _ids.length == 0 ? 0.0 : cast(double) _totalTokens / _ids.length;
    }

    /// Id of document number `doc`.
    string docId(size_t doc) const pure nothrow @nogc @safe
    {
        return _ids[doc];
    }

    /// Length `|d|` (token count) of document number `doc`.
    size_t docLength(size_t doc) const pure nothrow @nogc @safe
    {
        return _starts[doc].length;
    }

    /// The original text of document number `doc`.
    immutable(ubyte)[] docText(size_t doc) const pure nothrow @nogc @safe
    {
        return _texts[doc];
    }

    /// Byte offsets at which the tokens of document `doc` start.
    const(uint)[] tokenStarts(size_t doc) const pure nothrow @nogc @safe
    {
        return _starts[doc];
    }

    /// Byte offsets at which the tokens of document `doc` end (exclusive).
    const(uint)[] tokenEnds(size_t doc) const pure nothrow @nogc @safe
    {
        return _ends[doc];
    }

    /// Looks up a term; returns `noTerm` when it is not in the index.
    uint lookupTerm(const(char)[] term) const pure nothrow @trusted
    {
        if (auto p = cast(string) term in _termIds)
            return *p;
        return noTerm;
    }

    /// The postings of term id `term` (as returned by `lookupTerm`).
    ref const(Postings) postings(uint term) const pure nothrow @nogc @safe
    {
        return _postings[term];
    }
}
