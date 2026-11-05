/// Unit tests for the matcher: semantics from the specification.
module regexvm.test_matching;

import core.exception : AssertError;
import std.format : format;
import regexvm;

/// Renders a match in the CLI's output format.
private string run(string pattern, string subject)
{
    auto re = new Regex(pattern);
    OutputBuffer o;
    o.putResult(re.matchFirst(subject));
    auto s = cast(const(char)[]) o.data;
    return s[0 .. $ - 1].idup;
}

private void check(string pattern, string subject, string expected,
                   string file = __FILE__, size_t line = __LINE__)
{
    auto got = run(pattern, subject);
    if (got != expected)
        throw new AssertError(
            format("/%s/ on \"%s\": got '%s', expected '%s'", pattern, subject, got, expected),
            file, line);
}

unittest // literals, dot, search
{
    check("abc", "xxabcxx", "match 2 5");
    check("abc", "ab", "no");
    check("a.c", "abc", "match 0 3");
    check("", "xyz", "match 0 0");
    check("", "", "match 0 0");
    check("a b", "a  b a b", "match 5 8");
}

unittest // classes and escapes
{
    check("[a-c]+", "xxbcax", "match 2 5");
    check("[^a-c]+", "abxyc", "match 2 4");
    check(`\d+`, "ab123c", "match 2 5");
    check(`\w+`, "  foo_1 ", "match 2 7");
    check(`\s`, "ab c", "match 2 3");
    check(`\S+`, "  ab ", "match 2 4");
    check(`\D\W`, "1a-", "match 1 3");
    check(`\.\*\\`, `x.*\`, "match 1 4");
    check(`[\]\-]+`, "a]-b", "match 1 3");
    check(`[a-]+`, "x-a-", "match 1 4");
}

unittest // spec worked example 1
{
    check("(a|ab)(c|bcd)(d*)", "abcd", "match 0 4|0,1|1,4|4,4");
    check("a*", "bbb", "match 0 0");
    check("a*", "", "match 0 0");
    check("^(a+)+$", "aaaa", "match 0 4|0,4");
    check("^(a+)+$", "aaab", "no");
}

unittest // spec worked example 2
{
    check("(a|(b))+", "ba", "match 0 2|1,2|0,1");
    check("(a|(b))+", "ab", "match 0 2|1,2|1,2");
    check(`[^a]\d{2,3}x?`, "zz123xx", "match 1 6");
    check(`[^a-c]\d{2,3}x?`, "abc9", "no");
}

unittest // spec worked example 3
{
    check("(a*)*b", "aab", "match 0 3|2,2");
    check("(a*)*b", "ccc", "no");
    check("x$|^(y)?z", "xz", "no");
    check("x$|^(y)?z", "yz", "match 0 2|0,1");
    check("x$|^(y)?z", "zzz", "match 0 1|-");
    check("(a){0}b|(c)?(d)", "xb", "match 1 2|-|-|-");
    check("(a){0}b|(c)?(d)", "xcd", "match 1 3|-|1,2|2,3");
    check("(a){0}b|(c)?(d)", "d", "match 0 1|-|-|0,1");
}

unittest // ordered choice and greediness
{
    check("a|ab", "ab", "match 0 1");
    check("ab|a", "ab", "match 0 2");
    check("(a|b)*c|(a|ab)*c", "abc", "match 0 3|1,2|-");
}

unittest // leftmost beats longest
{
    check("b+|a", "aabbb", "match 0 1");
    check("a+", "baaa", "match 1 4");
}

unittest // counted quantifiers
{
    check("a{2}", "aaa", "match 0 2");
    check("a{2,}", "aaaa", "match 0 4");
    check("a{1,2}b", "aaab", "match 1 4");
    check("(ab){2,3}", "ababababab", "match 0 6|4,6");
    check("a{0}", "a", "match 0 0");
    check("(a){2}", "aa", "match 0 2|1,2");
}

unittest // anchors
{
    check("^a", "ba", "no");
    check("a$", "ab", "no");
    check("a$", "ba", "match 1 2");
    check("a^b", "ab", "no");
    check("^$", "", "match 0 0");
    check("^$", "a", "no");
    check("$", "abc", "match 3 3");
    check("(^a|b)+", "ab", "match 0 2|1,2");
}

unittest // empty iterations
{
    check("(a*)+", "b", "match 0 0|0,0");
    check("(a*){3}", "", "match 0 0|0,0");
    check("(a|)+", "aa", "match 0 2|2,2");
    check("(a*)*", "aa", "match 0 2|2,2");
    check("((a)|b)*", "ab", "match 0 2|1,2|0,1");
}

unittest // captures keep the last completed value; failed paths are undone
{
    check("(a)|b", "b", "match 0 1|-");
    check("(a)*b", "aab", "match 0 3|1,2");
    check("(a)?(b)?(c)?", "ac", "match 0 2|0,1|-|1,2");
    check("((a)|(b))*c", "abc", "match 0 3|1,2|0,1|1,2");
    check("(a+)(a+)", "aaa", "match 0 3|0,2|2,3");
    check("(x)(y)?(z)*", "xzz", "match 0 3|0,1|-|2,3");
}

unittest // backtracking into single-character loops
{
    check("a*ab", "aaab", "match 0 4");
    check(".*(.)", "abc", "match 0 3|2,3");
    check("[a-z]+1", "ab1", "match 0 3");
    check("a{2,3}a", "aaa", "match 0 3");
    check("a{2,3}a", "aa", "no");
}

unittest // pathological patterns terminate quickly
{
    import std.array : replicate;
    check("(x+x+)+y", "x".replicate(25), "no");
    check("(a|aa)+c", "a".replicate(30), "no");
    check("^(a+)+$", "a".replicate(26) ~ "b", "no");
    auto big = "a".replicate(10_000);
    check(".*b", big, "no");
    check("(.)*", big, "match 0 10000|9999,10000");
}

unittest // reusable Match and API surface
{
    auto re = new Regex("(a)(b)?");
    assert(re.groupCount == 2 && re.pattern == "(a)(b)?");
    Match m;
    assert(re.matchFirst("xab", m));
    assert(m.begin == 1 && m.end == 3 && m.groups.length == 2);
    assert(m.groups[0].of("xab") == "a" && m.groups[1].of("xab") == "b");
    assert(re.matchFirst("a", m));
    assert(!m.groups[1].isSet && m.groups[1].of("a") == "");
    assert(!re.matchFirst("zzz", m) && !m.matched);
    assert(re.test("a") && !re.test("b"));
}

unittest // subjects with spaces and pattern edge characters
{
    check(" ", "a b", "match 1 2");
    check(`\ `, "a b", "match 1 2");
    check("  *", "a  b", "match 1 3");
    check(`\{\}`, "{}", "match 0 2");
}
