/// Unit tests: glob compilation and matching.
module tests.test_glob;

import kiln.glob;

private bool m(string pat, string cand)
{
    GlobPattern p;
    assert(compileGlob(pat, p), "pattern should compile: " ~ pat);
    return globMatches(p, cand);
}

private bool bad(string pat)
{
    GlobPattern p;
    return !compileGlob(pat, p);
}

unittest // the examples of the specification
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
    assert(m("a/*", "a/"));
    assert(m("**/b", "a//b"));
}

unittest // malformed patterns
{
    assert(bad(""));
    assert(bad("/a"));
    assert(bad("a/"));
    assert(bad("a//b"));
    assert(bad("[]"));
    assert(bad("[!]"));
    assert(bad("[abc"));
    assert(bad("[z-a]"));
}

unittest // class edge cases
{
    assert(m("[-a]", "-") && m("[-a]", "a"));
    assert(m("[a-]", "-") && m("[a-]", "a"));
    assert(m("[*?]", "*") && m("[*?]", "?") && !m("[*?]", "x"));
    assert(m("x]", "x]"));
}

unittest // literal prefix narrowing
{
    GlobPattern p;
    assert(compileGlob("src/lib/*.d", p));
    assert(p.literalPrefix() == "src/lib");
    assert(compileGlob("**/x", p));
    assert(p.literalPrefix() == "");
    assert(compileGlob("a/b", p));
    assert(p.literalPrefix() == "a/b");
    assert(compileGlob("a/b*", p));
    assert(p.literalPrefix() == "a");
}
