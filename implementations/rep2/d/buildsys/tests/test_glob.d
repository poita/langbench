module test_glob;

import kiln.glob;

private bool m(string pat, string cand)
{
    auto g = GlobPattern.compile(pat);
    assert(g !is null, "pattern should compile: " ~ pat);
    return g.matches(cand);
}

unittest
{
    assert(m("src/*.txt", "src/a.txt"));
    assert(m("src/*.txt", "src/.txt"));
    assert(!m("src/*.txt", "src/sub/a.txt"));
    assert(!m("src/*.txt", "a.txt"));
}

unittest
{
    assert(m("src/**", "src/a.txt"));
    assert(m("src/**", "src/x/y/z.txt"));
    assert(m("src/**", "src"));
    assert(!m("src/**", "other/a.txt"));
    assert(!m("src/**", "srcx"));
    assert(m("**/*.txt", "a.txt"));
    assert(m("**/*.txt", "a/b/c.txt"));
    assert(!m("**/*.txt", "a.text"));
    assert(m("src/**/t_*.txt", "src/a/b/t_2.txt"));
    assert(m("src/**/t_*.txt", "src/t_1.txt"));
    assert(!m("src/**/t_*.txt", "src/t.txt"));
}

unittest
{
    assert(m("src/?.txt", "src/a.txt"));
    assert(!m("src/?.txt", "src/ab.txt"));
    assert(m("src/[ab]*.txt", "src/a1.txt"));
    assert(!m("src/[ab]*.txt", "src/c.txt"));
    assert(m("src/[!ab]*.txt", "src/c.txt"));
    assert(!m("src/[!ab]*.txt", "src/a.txt"));
    assert(m("src/[0-9].txt", "src/7.txt"));
    assert(!m("src/[0-9].txt", "src/x.txt"));
    assert(m("a**b", "axyzb"));
    assert(m("a**b", "ab"));
    assert(!m("a**b", "a/b"));
}

unittest
{
    // Candidates keep empty components.
    assert(m("*", ""));
    assert(m("**", ""));
    assert(!m("?", ""));
    assert(!m("*", "a//b"));
    assert(m("**", "a//b"));
    assert(m("a/*", "a/"));
}

unittest
{
    foreach (bad; ["", "/a", "a/", "a//b", "[", "[]", "[!]", "[a", "[z-a]", "a/[b"])
        assert(GlobPattern.compile(bad) is null, "should be malformed: " ~ bad);
    // '-' and wildcards are ordinary inside a class when reached as single items.
    assert(m("[-a]", "-"));
    assert(m("[a-]", "-"));
    assert(m("[*?]", "?"));
    assert(m("[a-c]", "b"));
}

unittest
{
    assert(GlobPattern.compile("src/a/*.txt").literalPrefix == "src/a");
    assert(GlobPattern.compile("src/**").literalPrefix == "src");
    assert(GlobPattern.compile("**/x").literalPrefix == "");
    assert(GlobPattern.compile("a/b").literalPrefix == "a/b");
    assert(GlobPattern.compile("a?/b").literalPrefix == "");
}
