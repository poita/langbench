module tests.hyphen_test;

import typeset.hyphen;
import tests.support : patternText;

unittest // Liang's algorithm on the traces of the specification
{
    auto ps = PatternSet.parse(patternText);
    assert(ps.left == 2 && ps.right == 3);
    assert(ps.hyphenate("winter") == [3]);
    assert(ps.hyphenate("typesetting") == [7, 8]);
}

unittest // exceptions override the patterns; an empty exception forbids breaks
{
    auto ps = PatternSet.parse(patternText);
    assert(ps.hyphenate("algorithm") == [2, 4]);
    assert(ps.hyphenate("through").length == 0);
}

unittest // minima and short words
{
    auto ps = PatternSet.parse(patternText);
    assert(ps.hyphenate("a").length == 0);
    assert(ps.hyphenate("nt").length == 0);
}

unittest // patterns with boundary markers only match at the word edges
{
    auto ps = PatternSet.parse("chp 1\nleft 1\nright 1\npattern .un1\npattern 1ed.\n");
    assert(ps.hyphenate("under") == [2]);
    assert(ps.hyphenate("tuned") == [3]);
    assert(ps.hyphenate("tunedx").length == 0);
}
