/// Unit tests for matching semantics (SPEC.md section 3 and its examples).
module regex.test_matcher;

import regex.api;
import regex.helpers;
import regex.vm;

unittest // literals, dot, anchors
{
    assert(render("abc", "xxabcxx") == "match 2 5");
    assert(render("abc", "ab") == "no");
    assert(render("a.c", "abc") == "match 0 3");
    assert(render("^a", "ba") == "no");
    assert(render("a$", "ab") == "no");
    assert(render("a$", "ba") == "match 1 2");
    assert(render("a^b", "ab") == "no");
    assert(render("^$", "") == "match 0 0");
    assert(render("", "abc") == "match 0 0");
    assert(render("$", "abc") == "match 3 3");
}

unittest // ordered choice
{
    assert(render("a|ab", "ab") == "match 0 1");
    assert(render("(a|ab)(c|bcd)(d*)", "abcd") == "match 0 4|0,1|1,4|4,4");
    assert(render("a|", "b") == "match 0 0");
    assert(render("(|b)", "b") == "match 0 0|0,0");
}

unittest // leftmost beats longest
{
    assert(render("a*", "bbb") == "match 0 0");
    assert(render("a+", "bbaaa") == "match 2 5");
}

unittest // greedy quantifiers and backtracking
{
    assert(render("a*ab", "aaab") == "match 0 4");
    assert(render("a{2,3}", "aaaa") == "match 0 3");
    assert(render("a{2,}", "aaaa") == "match 0 4");
    assert(render("a{2}", "a") == "no");
    assert(render("a?a", "a") == "match 0 1");
    assert(render("<.*>", "<a><b>") == "match 0 6");
    assert(render("x{0}y", "xy") == "match 1 2");
    assert(render("(ab){2}", "ababab") == "match 0 4|2,4");
}

unittest // classes and escapes
{
    assert(render("[^a-c]\\d{2,3}x?", "zz123xx") == "match 1 6");
    assert(render("[^a-c]\\d{2,3}x?", "abc9") == "no");
    assert(render(`\w+\s\W`, "ab_1 !") == "match 0 6");
    assert(render(`\S+`, "  ab ") == "match 2 4");
    assert(render(`a\.b`, "axb a.b") == "match 4 7");
    assert(render(`[\d-]+`, "ab12-3c") == "match 2 6");
    assert(render(`[a-c-]+`, "x-ab-") == "match 1 5");
}

unittest // captures: last iteration wins, skipped groups keep earlier values
{
    assert(render("(a|(b))+", "ba") == "match 0 2|1,2|0,1");
    assert(render("(a|(b))+", "ab") == "match 0 2|1,2|1,2");
    assert(render("(a)|(b)", "b") == "match 0 1|-|0,1");
    assert(render("(a){0}b|(c)?(d)", "xcd") == "match 1 3|-|1,2|2,3");
    assert(render("(a){0}b|(c)?(d)", "xb") == "match 1 2|-|-|-");
}

unittest // abandoned paths do not leak captures
{
    assert(render("(a)b|ac", "ac") == "match 0 2|-");
    assert(render("(a|ab)(c|bcd)", "abcd") == "match 0 4|0,1|1,4");
    assert(render("((a)|b)*c", "abc") == "match 0 3|1,2|0,1");
}

unittest // empty iterations
{
    assert(render("(a*)*b", "aab") == "match 0 3|2,2");
    assert(render("(a*)*b", "ccc") == "no");
    assert(render("(a*){3}", "") == "match 0 0|0,0");
    assert(render("(a*)+", "b") == "match 0 0|0,0");
    assert(render("(a?)*$", "aa") == "match 0 2|2,2");
    assert(render("(|a)+", "aa") == "match 0 0|0,0");
}

unittest // search order and filters
{
    assert(render("x$|^(y)?z", "xz") == "no");
    assert(render("x$|^(y)?z", "yz") == "match 0 2|0,1");
    assert(render("x$|^(y)?z", "zzz") == "match 0 1|-");
    assert(render("^(a+)+$", "aaaa") == "match 0 4|0,4");
    assert(render("^(a+)+$", "aaab") == "no");
    assert(render("b", "") == "no");
}

unittest // long subjects need no deep native recursion
{
    import std.array : replicate;
    auto s = "a".replicate(10000);
    assert(render(".*", s) == "match 0 10000");
    assert(render("(a|b)*c", s) == "no");
    assert(render("(a|b)*", s) == "match 0 10000|9999,10000");
}

unittest // pathological patterns terminate
{
    import std.array : replicate;
    assert(render("(a*)*b", "a".replicate(25) ~ "c") == "no");
    assert(render("(x+x+)+y", "x".replicate(22)) == "no");
}

unittest // a Matcher is reusable across patterns and subjects
{
    auto m = new Matcher;
    auto r1 = new Regex("(b+)");
    auto r2 = new Regex("a");
    assert(r1.search(m, "aabbb") && m.matchStart == 2 && m.matchEnd == 5);
    assert(m.captures == [2, 5]);
    assert(r2.search(m, "xa") && m.matchStart == 1);
    assert(m.captures.length == 0);
    assert(!r1.search(m, "zzz"));
}

unittest // Match helpers
{
    auto re = new Regex(`(\w+)@(\w+)`);
    enum subject = "mail bob@example now";
    auto m = re.search(subject);
    assert(m.matched && m.start == 5 && m.end == 16);
    assert(m.text(subject) == "bob@example");
    assert(m.groupText(subject, 1) == "bob");
    assert(m.groupText(subject, 2) == "example");
    assert(re.groupCount == 2 && m.groupCount == 2);
    assert(!re.search("none").matched);
}
