module tests.test_search;

import std.math : abs, log;

import fulltext;

private Index make(string[2][] docs...)
{
    Document[] ds;
    foreach (d; docs)
        ds ~= Document.fromString(d[0], d[1]);
    return new Index(ds);
}

private string[] ids(const SearchResult[] rs)
{
    string[] r;
    foreach (x; rs)
        r ~= x.docId;
    return r;
}

unittest // worked example from the specification
{
    auto idx = make(["note", "The quick brown fox jumps over the lazy dog.\n"]);
    assert(idx.docCount == 1);
    assert(idx.totalTokens == 9);
    assert(idx.termCount == 8);
    assert(idx.avgDocLength == 9.0);
    assert(formatStats(idx) == "documents 1\ntokens 9\nterms 8\navgdl 9.0000\n");

    auto eng = new SearchEngine(idx);
    auto r = eng.search("fox", 10);
    assert(r.length == 1);
    assert(abs(r[0].score - log(4.0 / 3.0)) < 1e-12);
    assert(r[0].snippet == "The quick brown fox jumps over the lazy dog");
    assert(abs(eng.search("quick brown", 10)[0].score - 2 * log(4.0 / 3.0)) < 1e-12);
    assert(eng.search("cat", 10).length == 0);
    assert(eng.search(`"lazy dog"`, 10).length == 1);
    assert(eng.search(`"dog lazy"`, 10).length == 0);
}

unittest // ties are broken by id; term frequency wins
{
    auto idx = make(["copy3", "alpha beta gamma"], ["copy1", "alpha beta gamma"],
            ["other", "alpha alpha beta"], ["copy2", "alpha beta gamma"]);
    auto eng = new SearchEngine(idx);
    auto r = eng.search("alpha", 10);
    assert(ids(r) == ["other", "copy1", "copy2", "copy3"]);
    assert(abs(r[0].score - 0.1449) < 5e-5);
    assert(abs(r[1].score - 0.1054) < 5e-5);
    assert(ids(eng.search("alpha", 2)) == ["other", "copy1"]);
}

unittest // boolean algebra
{
    auto idx = make(["1", "cat dog"], ["2", "cat"], ["3", "dog"], ["4", "bird"]);
    auto eng = new SearchEngine(idx);
    assert(ids(eng.search("cat dog", 10)) == ["1"]);
    assert(ids(eng.search("cat OR dog", 10)) == ["1", "2", "3"]);
    assert(ids(eng.search("cat NOT dog", 10)) == ["2"]);
    assert(ids(eng.search("NOT cat", 10)) == ["3", "4"]);
    assert(eng.search("NOT cat", 10)[0].score == 0);
    assert(eng.search("()", 10).length == 0); // the empty tree matches nothing
    assert(eng.search("the", 10).length == 0);
    assert(ids(eng.search("(cat OR bird) NOT dog", 10)) == ["4", "2"]);
}

unittest // phrases: adjacency, stop words and overlap
{
    auto idx = make(["a", "to be or not to be"], ["b", "be to"], ["c", "aa aa aa aa"]);
    auto eng = new SearchEngine(idx);
    assert(ids(eng.search(`"to be"`, 10)) == ["a"]);
    assert(ids(eng.search(`"to be or not to be"`, 10)) == ["a"]);
    assert(ids(eng.search(`"be or"`, 10)) == ["a"]);
    auto f = new SearchEngine(make(["c", "aa aa aa aa"], ["d", "aa aa"]));
    // "aa aa" occurs 3 times in c and once in d
    assert(ids(f.search(`"aa aa"`, 10)) == ["c", "d"]);
}

unittest // unknown terms and empty corpus
{
    auto eng = new SearchEngine(make(["a", "hello world"]));
    assert(eng.search("zebra", 10).length == 0);
    assert(eng.search(`"hello zebra"`, 10).length == 0);
    auto empty = new SearchEngine(new Index([]));
    assert(empty.search("anything", 10).length == 0);
    assert(empty.search("NOT anything", 10).length == 0);
    auto blank = new SearchEngine(make(["x", ""], ["y", "   "]));
    auto r = blank.search("NOT foo", 10);
    assert(ids(r) == ["x", "y"] && r[0].snippet == "" && r[0].score == 0);
}

unittest // matcher internals
{
    auto idx = make(["a", "x y x y x"], ["b", "y x"]);
    auto o = findOccurrences(idx, ["x", "y"]);
    assert(o.docs == [0]);
    assert(o.startsAt(0) == [0, 2]);
    auto single = findOccurrences(idx, ["x"]);
    assert(single.df == 2 && single.find(1) == 1 && single.find(5) == size_t.max);

    auto s = DocSet.empty(70);
    s.add(0);
    s.add(69);
    assert(s.count == 2 && s.contains(69) && !s.contains(1));
    auto c = s.complement();
    assert(c.count == 68 && !c.contains(0));
    uint[] seen;
    s.each((uint d) { seen ~= d; });
    assert(seen == [0, 69]);
}

unittest // ranking helpers
{
    assert(abs(idf(1, 1) - log(4.0 / 3.0)) < 1e-12);
    assert(termScore(1.0, 1, 9, 9) == 1.0);
    assert(termScore(1.0, 1, 0, 0) > 0); // avgdl 0 is tolerated
    auto top = topK([ScoredDoc(2, 1.0), ScoredDoc(0, 1.0), ScoredDoc(1, 2.0)], 2);
    assert(top == [ScoredDoc(1, 2.0), ScoredDoc(0, 1.0)]);
}

unittest // snippets: best window
{
    // 40 tokens: window starts range over 0 .. 10
    auto hits = [AtomHits(1, [35]), AtomHits(1, [37])];
    assert(bestWindowStart(40, hits) == 8); // smallest s covering 35 and 37
    assert(bestWindowStart(40, []) == 0);
    assert(bestWindowStart(20, hits) == 0);
    assert(bestWindowStart(40, [AtomHits(31, [3])]) == 0); // too long to fit
    // total occurrences break ties between equal distinct counts
    assert(bestWindowStart(40, [AtomHits(1, [0, 20, 22])]) == 0);
    assert(bestWindowStart(40, [AtomHits(1, [0, 35, 37])]) == 8);
}

unittest // snippet text keeps inner punctuation and collapses whitespace
{
    auto idx = make(["d", "  Hello,\n\n  big\tworld!  "]);
    auto eng = new SearchEngine(idx);
    assert(eng.search("big", 1)[0].snippet == "Hello, big world");
    auto big = make(["d", "x y"]);
    assert(new SearchEngine(big).search("x", 1)[0].snippet == "x y");
}

unittest // report formatting
{
    import std.array : appender;

    auto app = appender!string;
    formatQueryBlock(app, 3, "a b", [SearchResult("doc", 0.5, "snip"), SearchResult("e", 0, "")]);
    assert(app.data == "QUERY 3 a b\nHITS 2\n1\tdoc\t0.5000\tsnip\n2\te\t0.0000\t\n");
}
