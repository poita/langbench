module tests.test_query;

import std.conv : to;

import fulltext.query;
import fulltext.queryfile;

/// Renders a tree as an s-expression for comparison.
private string show(const Node n)
{
    if (n is null)
        return "()";
    final switch (n.kind)
    {
    case NodeKind.atom:
        string r = n.atom.terms[0];
        foreach (t; n.atom.terms[1 .. $])
            r ~= "_" ~ t;
        return r;
    case NodeKind.not:
        return "(NOT " ~ show(n.children[0]) ~ ")";
    case NodeKind.and:
        string r = "(AND";
        foreach (c; n.children)
            r ~= " " ~ show(c);
        return r ~ ")";
    case NodeKind.or:
        string r = "(OR";
        foreach (c; n.children)
            r ~= " " ~ show(c);
        return r ~ ")";
    }
}

private string p(string q)
{
    return show(parseQuery(q));
}

unittest // lexer
{
    auto t = lexQuery(`a AND "b c" (d) OR NOT and`);
    assert(t.length == 9);
    assert(t[1].kind == TokenKind.and);
    assert(t[2].kind == TokenKind.phrase && t[2].body == "b c");
    assert(t[3].kind == TokenKind.lparen && t[5].kind == TokenKind.rparen);
    assert(t[6].kind == TokenKind.or && t[7].kind == TokenKind.not);
    assert(t[8].kind == TokenKind.phrase && t[8].body == "and");
}

unittest // atoms
{
    Atom a;
    assert(!analyzeAtom("", a));
    assert(!analyzeAtom("the", a)); // single stop word
    assert(!analyzeAtom("!!", a));
    assert(analyzeAtom("to be or not to be", a) && a.terms.length == 6);
    assert(analyzeAtom("well-known", a) && a.terms == ["well", "known"]);
    assert(analyzeAtom("Running", a) && a.terms == ["run"]);
}

unittest // empty trees
{
    assert(p("") == "()");
    assert(p("()") == "()");
    assert(p("the") == "()");
    assert(p("NOT") == "()");
}

unittest // repairs described in the specification
{
    foreach (q; ["cat AND", "OR cat", "cat ()", "cat NOT ()", "cat NOT (", "(cat", `"cat`])
        assert(p(q) == "cat", q);
    assert(p("cat ) dog") == "cat");
    assert(p("cat ) ) dog") == "cat");
    assert(p("cat OR AND dog") == "(OR cat dog)");
    assert(p("cat AND OR dog") == "(OR cat dog)");
    assert(p("cat AND AND dog") == "(AND cat dog)");
    assert(p("dog NOT ( cat") == "(AND dog (NOT cat))");
}

unittest // precedence
{
    assert(p("cat dog") == "(AND cat dog)");
    assert(p("cat OR dog fox") == "(OR cat (AND dog fox))");
    assert(p("cat OR NOT dog fox") == "(OR cat (AND (NOT dog) fox))");
    assert(p("(cat OR dog) fox") == "(AND (OR cat dog) fox)");
    assert(p("NOT NOT cat") == "(NOT (NOT cat))");
}

unittest // positive atoms
{
    string[] keys(string q)
    {
        string[] r;
        foreach (a; positiveAtoms(parseQuery(q)))
            r ~= a.key;
        return r;
    }

    assert(keys("NOT cat") == []);
    assert(keys("cat NOT dog cat") == ["cat"]);
    assert(keys("NOT (cat NOT dog)") == ["dog"]);
    assert(keys("dog cat dog") == ["dog", "cat"]);
    assert(keys("") == []);
}

unittest // query files
{
    auto es = parseQueryFile("# c\n\nfoo\n%k 3\n  bar baz  \n%k\t7 \nqux");
    assert(es.length == 3);
    assert(es[0].number == 1 && es[0].text == "foo" && es[0].k == 10);
    assert(es[1].number == 2 && es[1].text == "bar baz" && es[1].k == 3);
    assert(es[2].number == 3 && es[2].text == "qux" && es[2].k == 7);
    assert(parseQueryFile("").length == 0);

    size_t k;
    assert(parseKDirective("%k 12", k) && k == 12);
    assert(!parseKDirective("%k", k));
    assert(!parseKDirective("%k x", k));
    assert(!parseKDirective("%k 1 2", k));
    assert(!parseKDirective("%k5", k));
}
