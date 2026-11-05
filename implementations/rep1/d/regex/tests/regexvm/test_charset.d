/// Unit tests for regexvm.charset.
module regexvm.test_charset;

import regexvm.charset;

unittest // single bytes and ranges
{
    CharSet s;
    assert(s.isEmpty);
    s.add('a');
    s.addRange('0', '3');
    assert(s.contains('a') && s.contains('0') && s.contains('3'));
    assert(!s.contains('4') && !s.contains('b'));
    assert(s.count == 5);
}

unittest // negation covers all 256 values
{
    auto s = CharSet.digit();
    s.negate();
    assert(!s.contains('5') && s.contains('a') && s.contains(200));
    assert(s.count == 246);
    s.addSet(CharSet.digit());
    assert(s.isFull);
}

unittest // escapes
{
    CharSet s;
    assert(CharSet.forEscape('w', s));
    assert(s.contains('_') && s.contains('Z') && s.contains('9') && !s.contains('-'));
    assert(CharSet.forEscape('S', s));
    assert(!s.contains(' ') && !s.contains('\t') && s.contains('x'));
    assert(CharSet.forEscape('D', s) && s.contains('x') && !s.contains('0'));
    assert(!CharSet.forEscape('x', s));
    assert(CharSet.space().count == 6);
}
