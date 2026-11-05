/// Unit tests for the parser and character sets.
module regex.test_parser;

import std.exception : assertThrown, assertNotThrown;

import regex.ast;
import regex.charset;
import regex.parser;

unittest // groups are numbered by their opening parenthesis
{
    auto p = parse("(a(b))(c)");
    assert(p.groupCount == 3);
    assert(p.root.kind == NodeKind.seq);
    assert(p.root.children[0].group == 1);
    assert(p.root.children[0].children[0].children[1].group == 2);
    assert(p.root.children[1].group == 3);
}

unittest // alternation and empty branches
{
    auto p = parse("a||b");
    assert(p.root.kind == NodeKind.alt && p.root.children.length == 3);
    assert(p.root.children[1].children.length == 0);
    assert(parse("").root.kind == NodeKind.seq);
    assertNotThrown(parse("()"));
    assertNotThrown(parse("(|b)"));
}

unittest // quantifier forms
{
    auto r = parse("a{2,5}").root.children[0];
    assert(r.kind == NodeKind.repeat && r.min == 2 && r.max == 5);
    r = parse("a{3}").root.children[0];
    assert(r.min == 3 && r.max == 3);
    r = parse("a{3,}").root.children[0];
    assert(r.min == 3 && r.max < 0);
    r = parse("a*").root.children[0];
    assert(r.min == 0 && r.max < 0);
    r = parse("a+").root.children[0];
    assert(r.min == 1 && r.max < 0);
    r = parse("a?").root.children[0];
    assert(r.min == 0 && r.max == 1);
    r = parse("a{0}").root.children[0];
    assert(r.min == 0 && r.max == 0);
}

unittest // classes
{
    auto s = parse("[a-c_]").root.children[0].set;
    assert(s.has('a') && s.has('b') && s.has('c') && s.has('_'));
    assert(!s.has('d') && !s.has('-'));

    s = parse("[^a-c]").root.children[0].set;
    assert(!s.has('b') && s.has('d'));

    s = parse("[-a]").root.children[0].set;
    assert(s.has('-') && s.has('a'));
    s = parse("[a-]").root.children[0].set;
    assert(s.has('-') && s.has('a') && !s.has('b'));
    s = parse(`[a\-z]`).root.children[0].set;
    assert(s.has('-') && s.has('a') && s.has('z') && !s.has('b'));
    s = parse("[a^]").root.children[0].set;
    assert(s.has('^'));
    s = parse(`[\]\[\\]`).root.children[0].set;
    assert(s.has(']') && s.has('[') && s.has('\\'));
    s = parse(`[\d_]`).root.children[0].set;
    assert(s.has('5') && s.has('_') && !s.has('a'));
    s = parse(`[\D]`).root.children[0].set;
    assert(!s.has('5') && s.has('a'));
}

unittest // escapes outside classes
{
    auto d = parse(`\d`).root.children[0];
    assert(d.kind == NodeKind.set && d.set.has('7') && !d.set.has('x'));
    auto w = parse(`\W`).root.children[0];
    assert(w.set.has(' ') && !w.set.has('_'));
    auto sp = parse(`\s`).root.children[0];
    assert(sp.set.has(' ') && sp.set.has('\t') && !sp.set.has('a'));
    auto lit = parse(`\.`).root.children[0];
    assert(lit.kind == NodeKind.literal && lit.ch == '.');
    assert(parse(`\ `).root.children[0].ch == ' ');
    assert(parse(`\-`).root.children[0].ch == '-');
}

unittest // invalid patterns are rejected
{
    foreach (bad; ["(", ")", "a)", "[a", "[]", "*", "a**", "a{2", "a{3,2}", "a{x}",
            `a\`, `\q`, "^*", "a{2}{3}", "[b-a]", "]", "}", "{1}"])
        assertThrown!RegexException(parse(bad), bad);
}

unittest // charset basics
{
    CharSet s;
    assert(s.count == 0);
    s.addRange('a', 'e');
    assert(s.count == 5 && s.has('c') && !s.has('f'));
    s.negate();
    assert(s.count == 251 && !s.has('c') && s.has('f'));
    assert(CharSet.full().isFull());
    ubyte[256] t;
    CharSet.digits().toTable(t);
    assert(t['0'] == 1 && t['9'] == 1 && t['a'] == 0);
}
