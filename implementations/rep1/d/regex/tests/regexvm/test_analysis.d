/// Unit tests for regexvm.analysis.
module regexvm.test_analysis;

import regexvm.analysis;
import regexvm.parser;

private bool nullable(string p) { return isNullable(parse(p).root); }
private bool anchored(string p) { return isAnchoredAtStart(parse(p).root); }

unittest // nullability
{
    assert(nullable(""));
    assert(nullable("a*"));
    assert(nullable("a?b?"));
    assert(nullable("^"));
    assert(nullable("$"));
    assert(nullable("a{0}"));
    assert(nullable("a|"));
    assert(nullable("(a*)*"));
    assert(!nullable("a"));
    assert(!nullable("a+"));
    assert(!nullable("a*b"));
    assert(!nullable("(a|b)c*"));
    assert(nullable("(a|b)*"));
    assert(nullable("(^|a)+"));
}

unittest // start anchoring
{
    assert(anchored("^a"));
    assert(anchored("^"));
    assert(anchored("^a|^b"));
    assert(anchored("(^a)b"));
    assert(anchored("(^a)+"));
    assert(anchored("(^a|^b)c"));
    assert(!anchored("a^"));
    assert(!anchored("^a|b"));
    assert(!anchored("(^a)*"));
    assert(!anchored("(^a){0}"));
    assert(!anchored(""));
    assert(!anchored("a|"));
}

unittest // first-byte sets
{
    auto f = firstInfo(parse("ab").root);
    assert(!f.nullable && f.set.count == 1 && f.set.contains('a'));

    f = firstInfo(parse("a*b").root);
    assert(!f.nullable && f.set.count == 2 && f.set.contains('a') && f.set.contains('b'));

    f = firstInfo(parse("^x?$").root);
    assert(f.nullable && f.set.count == 1 && f.set.contains('x'));

    f = firstInfo(parse("(a|bc)d").root);
    assert(f.set.count == 2 && f.set.contains('a') && f.set.contains('b'));

    f = firstInfo(parse(".a").root);
    assert(f.set.isFull);

    f = firstInfo(parse("a{0}b").root);
    assert(f.set.count == 1 && f.set.contains('b'));

    f = firstInfo(parse(`\d+`).root);
    assert(!f.nullable && f.set.count == 10);
}
