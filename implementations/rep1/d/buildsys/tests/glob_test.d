/// Unit tests for kiln.glob.
module glob_test;

import kiln.glob;

private bool m(string pat, string cand)
{
    auto g = GlobPattern.compile(pat);
    assert(g !is null, pat);
    return g.matches(cand);
}

unittest // table from the specification
{
    assert(m("src/*.txt", "src/a.txt") && m("src/*.txt", "src/.txt"));
    assert(!m("src/*.txt", "src/sub/a.txt") && !m("src/*.txt", "a.txt"));
    assert(m("src/**", "src/a.txt") && m("src/**", "src/x/y/z.txt") && m("src/**", "src"));
    assert(!m("src/**", "other/a.txt") && !m("src/**", "srcx"));
    assert(m("**/*.txt", "a.txt") && m("**/*.txt", "src/a.txt") && m("**/*.txt", "a/b/c.txt"));
    assert(!m("**/*.txt", "a.text"));
    assert(m("src/**/t_*.txt", "src/t_1.txt") && m("src/**/t_*.txt", "src/a/b/t_2.txt"));
    assert(!m("src/**/t_*.txt", "src/t.txt"));
    assert(m("src/?.txt", "src/a.txt") && !m("src/?.txt", "src/ab.txt"));
    assert(m("src/[ab]*.txt", "src/a1.txt") && m("src/[ab]*.txt", "src/b.txt"));
    assert(!m("src/[ab]*.txt", "src/c.txt"));
    assert(m("src/[!ab]*.txt", "src/c.txt") && !m("src/[!ab]*.txt", "src/a.txt"));
    assert(m("src/[0-9].txt", "src/7.txt") && !m("src/[0-9].txt", "src/x.txt"));
    assert(m("a**b", "axyzb") && m("a**b", "ab") && !m("a**b", "a/b"));
}

unittest // empty candidate components are kept
{
    assert(m("*", ""));
    assert(m("**", ""));
    assert(!m("?", ""));
    assert(!m("*", "a//b"));
    assert(m("a/*/b", "a//b"));
    assert(m("*/*", "x/"));
}

unittest // malformed patterns
{
    foreach (bad; ["", "/a", "a/", "a//b", "[", "[]", "[!]", "[b-a]", "a[bc"])
        assert(GlobPattern.compile(bad) is null, bad);
}

unittest // class item scanning
{
    assert(m("[-a]", "-") && m("[-a]", "a"));
    assert(m("[a-]", "a") && m("[a-]", "-"));
    assert(m("[*?]", "*") && m("[*?]", "?") && !m("[*?]", "x"));
    assert(m("[a-c-]", "-"));
    assert(GlobPattern.compile("[]a]") is null);
}

unittest // literal prefix used for index narrowing
{
    assert(GlobPattern.compile("src/*.txt").literalPrefix == "src");
    assert(GlobPattern.compile("src/lib/a.txt").literalPrefix == "src/lib/a.txt");
    assert(GlobPattern.compile("**/x").literalPrefix == "");
    assert(GlobPattern.compile("a/b*/c").literalPrefix == "a");
}

unittest // several `**` do not blow up
{
    assert(!m("**/**/**/**/**/x", "a/a/a/a/a/a/a/a/a/a/a/a/a/y"));
    assert(m("**/**/**/x", "a/b/x"));
}
