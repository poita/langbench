/// Behavioural tests for the matching semantics (compiled only for `dub test`).
module btregex.tests;

version (unittest)
{
    import std.array : join;
    import std.format : format;
    import btregex;

    /// Runs `pattern` on `subject` and renders the result like the CLI does.
    private string render(string pattern, string subject)
    {
        ubyte[] result;
        auto re = new Regex(pattern);
        auto m = re.search(subject);
        auto o = OutputBuffer((const(ubyte)[] b) { result ~= b; });
        formatMatch(o, m);
        o.flush();
        return cast(string) result;
    }

    private void check(string pattern, string subject, string expected,
        string file = __FILE__, size_t line = __LINE__)
    {
        const got = render(pattern, subject);
        assert(got == expected, format("/%s/ on '%s': got '%s', want '%s'", pattern, subject, got, expected));
    }

    @("worked examples from the specification")
    unittest
    {
        check("(a|ab)(c|bcd)(d*)", "abcd", "match 0 4|0,1|1,4|4,4");
        check("a*", "bbb", "match 0 0");
        check("a*", "", "match 0 0");
        check("^(a+)+$", "aaaa", "match 0 4|0,4");
        check("^(a+)+$", "aaab", "no");
        check("(a|(b))+", "ba", "match 0 2|1,2|0,1");
        check("(a|(b))+", "ab", "match 0 2|1,2|1,2");
        check("[^a-c]\\d{2,3}x?", "zz123xx", "match 1 6");
        check("[^a-c]\\d{2,3}x?", "abc9", "no");
        check("(a*)*b", "aab", "match 0 3|2,2");
        check("x$|^(y)?z", "xz", "no");
        check("x$|^(y)?z", "yz", "match 0 2|0,1");
        check("x$|^(y)?z", "zzz", "match 0 1|-");
        check("(a){0}b|(c)?(d)", "xb", "match 1 2|-|-|-");
        check("(a){0}b|(c)?(d)", "xcd", "match 1 3|-|1,2|2,3");
        check("(a){0}b|(c)?(d)", "d", "match 0 1|-|-|0,1");
    }

    @("ordered choice, greedy and empty iterations")
    unittest
    {
        check("a|ab", "ab", "match 0 1");
        check("(a*){3}", "", "match 0 0|0,0");
        check("(a?)*", "aa", "match 0 2|2,2");
    }

    @("anchors")
    unittest
    {
        check("a^b", "ab", "no");
        check("^", "abc", "match 0 0");
        check("$", "abc", "match 3 3");
        check("^b", "ab", "no");
        check("(^|x)a", "xa", "match 0 2|0,1");
        check("(^|x)a", "a", "match 0 1|0,0");
    }

    @("classes and escapes")
    unittest
    {
        check("[a-c-]+", "xab-cx", "match 1 5");
        check("\\w+\\s\\D", "ab cd", "match 0 4");
        check("\\.\\*\\ ", "a.* b", "match 1 4");
        check("[\\]\\\\]", "x\\", "match 1 2");
        check("[^]a]", "]ab", "match 2 3");
    }

    @("counted quantifiers")
    unittest
    {
        check("a{2,3}", "aaaa", "match 0 3");
        check("a{2,}", "aaaa", "match 0 4");
        check("a{0}", "aaaa", "match 0 0");
        check("(ab){2}", "ababab", "match 0 4|2,4");
        check("(a|b){1,2}c", "abc", "match 0 3|1,2");
    }

    @("pathological patterns terminate")
    unittest
    {
        import std.array : replicate;

        check("(x+x+)+y", "x".replicate(18), "no");
        check("(a|aa)+c", "a".replicate(25), "no");
        check("a*b", "a".replicate(1000), "no");
    }
}
