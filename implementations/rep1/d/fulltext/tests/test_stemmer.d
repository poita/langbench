module tests.test_stemmer;

import std.algorithm : splitter;
import std.string : lineSplitter;

import fulltext.stemmer;

unittest // worked stems from the specification
{
    immutable string[2][] cases = [
        ["running", "run"], ["runs", "run"], ["runner", "runner"],
        ["connection", "connect"], ["connections", "connect"],
        ["connecting", "connect"], ["cats", "cat"], ["dogs", "dog"],
        ["happiness", "happi"], ["happier", "happier"],
        ["relational", "relat"], ["relativity", "rel"],
        ["sensibility", "sensibl"], ["national", "nation"],
        ["controlled", "control"], ["abandoned", "abandon"],
    ];
    foreach (c; cases)
        assert(stem(c[0]) == c[1], c[0]);
}

unittest // step 1b: rule selected by suffix alone
{
    foreach (w; ["feed", "need", "bleed", "deed"])
        assert(stem(w) == w);
    assert(stem("agreed") == "agre");
}

unittest // short words are untouched
{
    assert(stem("a") == "a");
    assert(stem("is") == "is");
    assert(stem("as") == "as");
}

unittest // departures from the paper
{
    assert(stem("conformabli") == "conform");
    assert(stem("apologi") == "apolog");
}

unittest // step 5
{
    assert(stem("probate") == "probat");
    assert(stem("rate") == "rate");
    assert(stem("cease") == "ceas");
    assert(stem("controll") == "control");
    assert(stem("roll") == "roll");
}

unittest // in-place stemming reports the new length
{
    char[] buf = "caresses".dup;
    immutable n = stemInPlace(buf);
    assert(buf[0 .. n] == "caress");
}

unittest // a sample of Porter's own vocabulary ("word stem" per line)
{
    enum data = import("porter_sample.txt");
    size_t checked;
    foreach (line; data.lineSplitter)
    {
        if (line.length == 0)
            continue;
        auto parts = line.splitter(' ');
        immutable word = parts.front;
        parts.popFront();
        immutable expected = parts.front;
        assert(stem(word) == expected, word);
        ++checked;
    }
    assert(checked > 1000);
}
