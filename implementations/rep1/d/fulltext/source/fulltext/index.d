/**
 * The positional inverted index.
 *
 * An $(LREF Index) maps every term to its $(LREF Occurrences): for each
 * document containing the term, the sorted positions at which it occurs.
 * It also keeps the document texts and lengths and the corpus statistics
 * needed for ranking.
 */
module fulltext.index;

import fulltext.analysis;

@safe:

/// A document to be indexed.
struct Document
{
    /// Unique identifier (compared and ordered by UTF-8 byte order).
    string id;
    /// The full text of the document.
    string text;
}

/**
 * A read-only view of positional postings: a sorted list of document numbers
 * and, for each, the sorted positions of the term (or phrase) in it.
 *
 * Positions of the `i`-th document are
 * `positions[starts[i] .. (i + 1 < docs.length ? starts[i + 1] : positions.length)]`.
 */
struct Occurrences
{
    /// Sorted document numbers.
    const(uint)[] docs;
    /// For each document, the offset of its first position in `positions`.
    const(uint)[] starts;
    /// Concatenated position lists.
    const(uint)[] positions;

    /// Number of documents.
    @property size_t length() const pure nothrow @nogc { return docs.length; }

    /// True if no document is present.
    @property bool empty() const pure nothrow @nogc { return docs.length == 0; }

    /// The positions in the `i`-th document of the list.
    const(uint)[] positionsAt(size_t i) const pure nothrow @nogc
    {
        immutable e = i + 1 < docs.length ? starts[i + 1] : positions.length;
        return positions[starts[i] .. e];
    }

    /// Index into `docs` of document `doc`, or `size_t.max` if absent.
    size_t find(uint doc) const pure nothrow @nogc
    {
        size_t lo = 0, hi = docs.length;
        while (lo < hi)
        {
            immutable mid = lo + (hi - lo) / 2;
            if (docs[mid] < doc)
                lo = mid + 1;
            else
                hi = mid;
        }
        return lo < docs.length && docs[lo] == doc ? lo : size_t.max;
    }
}

private struct PostingList
{
    uint[] docs;
    uint[] starts;
    uint[] positions;

    Occurrences view() const pure nothrow @nogc
    {
        return Occurrences(docs, starts, positions);
    }
}

/// An inverted index over a set of documents.
final class Index
{
    private
    {
        Document[] docs_;
        uint[] lengths_;
        PostingList[] postings_;
        uint[string] termIds_;
        // Cache from folded token text to term id (avoids re-stemming).
        uint[string] textToTerm_;
        ulong totalTokens_;
        char[] foldBuf_;
    }

    /// Adds a document and returns its number (0-based, in insertion order).
    uint addDocument(string id, string text)
    {
        assert(docs_.length < uint.max);
        immutable docNo = cast(uint) docs_.length;
        docs_ ~= Document(id, text);
        uint length = 0;
        foreach (tok; tokenize(text))
        {
            immutable tid = termIdFor(text[tok.begin .. tok.end]);
            auto pl = &postings_[tid];
            if (pl.docs.length == 0 || pl.docs[$ - 1] != docNo)
            {
                pl.docs ~= docNo;
                pl.starts ~= cast(uint) pl.positions.length;
            }
            pl.positions ~= tok.position;
            length++;
        }
        lengths_ ~= length;
        totalTokens_ += length;
        return docNo;
    }

    /// Builds an index over `documents`.
    static Index build(const(Document)[] documents)
    {
        auto ix = new Index;
        foreach (d; documents)
            ix.addDocument(d.id, d.text);
        return ix;
    }

    private uint termIdFor(const(char)[] raw)
    {
        auto folded = foldInto(raw, foldBuf_);
        if (auto p = lookupText(folded))
            return *p;
        immutable term = termOf(folded);
        uint tid;
        if (auto p = term in termIds_)
            tid = *p;
        else
        {
            tid = cast(uint) postings_.length;
            postings_ ~= PostingList.init;
            termIds_[term] = tid;
        }
        textToTerm_[folded.idup] = tid;
        return tid;
    }

    private const(uint)* lookupText(const(char)[] folded) const @trusted
    {
        // The key is only read for the lookup, never stored.
        return cast(string) folded in textToTerm_;
    }

    /// Number of documents, `N`.
    @property size_t documentCount() const pure nothrow @nogc { return docs_.length; }

    /// Total number of tokens over all documents.
    @property ulong tokenCount() const pure nothrow @nogc { return totalTokens_; }

    /// Number of distinct terms.
    @property size_t termCount() const pure nothrow @nogc { return postings_.length; }

    /// Mean document length; 0 for an empty corpus.
    @property double averageLength() const pure nothrow @nogc
    {
        return docs_.length == 0 ? 0.0 : cast(double) totalTokens_ / docs_.length;
    }

    /// The identifier of document `doc`.
    string id(uint doc) const pure nothrow @nogc { return docs_[doc].id; }

    /// The text of document `doc`.
    string text(uint doc) const pure nothrow @nogc { return docs_[doc].text; }

    /// The number of tokens in document `doc`.
    uint length(uint doc) const pure nothrow @nogc { return lengths_[doc]; }

    /// Postings of `term` (an already-analysed term); empty if unknown.
    Occurrences lookup(const(char)[] term) const
    {
        if (auto p = term in termIds_)
            return postings_[*p].view();
        return Occurrences.init;
    }
}

unittest
{
    auto ix = new Index;
    ix.addDocument("a", "The quick brown fox jumps over the lazy dog.");
    ix.addDocument("b", "");
    assert(ix.documentCount == 2);
    assert(ix.tokenCount == 9);
    assert(ix.termCount == 8);
    assert(ix.averageLength == 4.5);
    assert(ix.length(0) == 9 && ix.length(1) == 0);

    auto the = ix.lookup("the");
    assert(the.docs == [0]);
    assert(the.positionsAt(0) == [0, 6]);
    assert(ix.lookup("jump").positionsAt(0) == [4]);
    assert(ix.lookup("jumps").empty);
    assert(the.find(0) == 0 && the.find(1) == size_t.max);
}

unittest
{
    auto ix = Index.build([Document("x", "a b a"), Document("y", "b b")]);
    auto b = ix.lookup("b");
    assert(b.docs == [0, 1]);
    assert(b.positionsAt(0) == [1]);
    assert(b.positionsAt(1) == [0, 1]);
    assert(ix.lookup("nothing").length == 0);
    assert(new Index().averageLength == 0);
}
