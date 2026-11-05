module tests.test_analysis;

import std.algorithm : map;
import std.array : array;

import fulltext.analysis;
import fulltext.whitespace;

private string[] tokens(string text)
{
    return Tokenizer(text).map!(s => text[s.start .. s.end]).array;
}

unittest // tokeniser examples from the specification
{
    assert(tokens("The cat sat.") == ["The", "cat", "sat"]);
    assert(tokens("don't stop") == ["don't", "stop"]);
    assert(tokens("'quoted'") == ["quoted"]);
    assert(tokens("rock'n'roll") == ["rock'n'roll"]);
    assert(tokens("a''b") == ["a", "b"]);
    assert(tokens("well-known") == ["well", "known"]);
    assert(tokens("Version 1.2.3") == ["Version", "1", "2", "3"]);
    assert(tokens("X1 XY2Z") == ["X1", "XY2Z"]);
    assert(tokens("Don’t") == ["Don’t"]);
}

unittest // token characters and separators
{
    assert(tokens("café × ÷ naïve") == ["café", "naïve"]);
    assert(tokens("Жук αβ") == ["Жук", "αβ"]);
    assert(tokens("中文 text — more") == ["text", "more"]);
    assert(tokens("") == []);
    assert(tokens("  ...  ") == []);
}

unittest // spans are byte offsets
{
    auto spans = Tokenizer("éa bc").array;
    assert(spans == [Span(0, 3), Span(4, 6)]);
}

unittest // folding and terms
{
    TermAnalyzer an;
    bool stop;
    assert(an.fold(cast(const(ubyte)[]) "Don’T") == "dont");
    assert(an.fold(cast(const(ubyte)[]) "CAFÉ") == "cafÉ");
    assert(an.analyze(cast(const(ubyte)[]) "Running", stop) == "run");
    assert(!stop);
    assert(an.analyze(cast(const(ubyte)[]) "The", stop) == "the");
    assert(stop);
    assert(an.analyze(cast(const(ubyte)[]) "x1s", stop) == "x1s"); // digits: never stemmed
    assert(an.analyze(cast(const(ubyte)[]) "cafés", stop) == "cafés");
}

unittest // stop words
{
    assert(stopWords.length == 33);
    foreach (w; stopWords)
        assert(isStopWord(w));
    assert(!isStopWord("cat"));
    assert(!isStopWord(""));
}

unittest // analyzeText
{
    assert(analyzeText("The quick brown fox jumps over the lazy dog.")
            == ["the", "quick", "brown", "fox", "jump", "over", "the", "lazi", "dog"]);
}

unittest // whitespace helpers
{
    assert(stripSpace("\t   hi there  \n") == "hi there");
    assert(stripSpace("") == "");
    assert(stripSpace("   ") == "");
    assert(collapseSpace(cast(const(ubyte)[]) "a \n\t b  c") == "a b c");
}
