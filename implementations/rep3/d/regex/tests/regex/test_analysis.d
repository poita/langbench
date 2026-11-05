/// Unit tests for the static analysis and the compiler's use of it.
module regex.test_analysis;

import regex.analysis;
import regex.charset;
import regex.compiler;
import regex.parser;
import regex.program;

private bool anchored(string p) { return isAnchored(parse(p).root); }

private CharSet first(string p, out bool nullable)
{
    CharSet s;
    nullable = firstChars(parse(p).root, s);
    return s;
}

unittest // anchoring
{
    assert(anchored("^a"));
    assert(anchored("^"));
    assert(anchored("^a|^b"));
    assert(!anchored("^a|b"));
    assert(anchored("(^a)"));
    assert(anchored("(^a)+"));
    assert(!anchored("(^a)*"));
    assert(!anchored("(^a){0}b"));
    assert(!anchored("a^"));
    assert(!anchored("a|"));
}

unittest // first-character sets
{
    bool nl;
    auto s = first("abc", nl);
    assert(!nl && s.count == 1 && s.has('a'));
    s = first("a*b", nl);
    assert(!nl && s.count == 2 && s.has('a') && s.has('b'));
    s = first("a*", nl);
    assert(nl);
    s = first("a|", nl);
    assert(nl);
    s = first("^a", nl);
    assert(!nl && s.count == 1 && s.has('a'));
    s = first(".b", nl);
    assert(!nl && s.isFull());
    s = first("(a){0}b", nl);
    assert(!nl && s.count == 1 && s.has('b'));
}

unittest // the compiler only enables the filter when it is safe and useful
{
    assert(compile("abc").useFirstSet);
    assert(!compile("a*").useFirstSet);
    assert(!compile(".a").useFirstSet);
    assert(!compile("$").useFirstSet);
    assert(compile("^a").anchored);
    assert(!compile("^a").useFirstSet);
}

unittest // single-character repeats compile to one instruction
{
    auto p = compile("a{2,5}");
    assert(p.code.length == 2); // charLoop + match
    assert(p.code[0].op == Op.charLoop);
    p = compile("[a-z]*");
    assert(p.code[0].op == Op.charLoop);
}

unittest // mark/check only for bodies that can match empty
{
    import std.algorithm : canFind, any;
    auto withGuard = compile("(a*)*");
    auto without = compile("(a)*");
    assert(withGuard.code.any!(i => i.op == Op.check));
    assert(!without.code.any!(i => i.op == Op.check || i.op == Op.mark));
}

unittest // x{0} emits nothing; group slots stay unset
{
    auto p = compile("(a){0}");
    assert(p.code.length == 1 && p.code[0].op == Op.match);
    assert(p.groupCount == 1);
}

unittest // runaway expansion is rejected
{
    import std.exception : assertThrown;
    assertThrown!RegexException(compile("((((a{1000}){1000}){1000}){1000})"));
}
