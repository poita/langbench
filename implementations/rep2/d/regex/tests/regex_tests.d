/// Unit tests for the regex library.
module regex_tests;

import std.format : format;

import regex;
import regex.analysis;
import regex.ast;
import regex.charset;
import regex.compiler;
import regex.parser;
import regex.program;

/// Renders a search the way the CLI does, using the library API.
private string run(string pattern, string subject)
{
    auto re = new Regex(pattern);
    auto m = re.search(subject);
    if (!m.matched)
        return "no";
    string r = format("match %d %d", m.begin, m.end);
    foreach (g; m.groups)
        r ~= g.isSet ? format("|%d,%d", g.begin, g.end) : "|-";
    return r;
}

private void check(string pattern, string subject, string expected, string file = __FILE__, size_t line = __LINE__)
{
    const got = run(pattern, subject);
    assert(got == expected, format("/%s/ on \"%s\": expected %s, got %s", pattern, subject, expected, got));
}

// ---- spec examples ---------------------------------------------------------

unittest
{
    check("(a|ab)(c|bcd)(d*)", "abcd", "match 0 4|0,1|1,4|4,4");
    check("a*", "bbb", "match 0 0");
    check("a*", "", "match 0 0");
    check("^(a+)+$", "aaaa", "match 0 4|0,4");
    check("^(a+)+$", "aaab", "no");
}

unittest
{
    check("(a|(b))+", "ba", "match 0 2|1,2|0,1");
    check("(a|(b))+", "ab", "match 0 2|1,2|1,2");
    check("[^a-c]\\d{2,3}x?", "zz123xx", "match 1 6");
    check("[^a-c]\\d{2,3}x?", "abc9", "no");
}

unittest
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

// ---- semantics -------------------------------------------------------------

unittest // ordered choice and greediness
{
    check("a|ab", "ab", "match 0 1");
    check("a+", "aaa", "match 0 3");
}

unittest // anchors
{
    check("a^b", "ab", "no");
    check("^$", "", "match 0 0");
    check("$", "abc", "match 3 3");
    check("^abc", "xabc", "no");
}

unittest // empty groups and branches
{
    check("()", "x", "match 0 0|0,0");
    check("a|", "b", "match 0 0");
    check("(|b)", "b", "match 0 0|0,0");
    check("||", "", "match 0 0");
}

unittest // counted repetition
{
    check("(a*){3}", "", "match 0 0|0,0");
    check("a{2,3}", "aaaa", "match 0 3");
    check("a{2,}", "aaaa", "match 0 4");
    check("a{0}b", "ab", "match 1 2");
    check("(ab){2}", "ababab", "match 0 4|2,4");
    check("(a|b){1,2}c", "abc", "match 0 3|1,2");
    check("(a{2}){2}", "aaaaa", "match 0 4|2,4");
}

unittest // empty iterations end a repetition
{
    check("(a*)+", "b", "match 0 0|0,0");
    check("(a|)+b", "aab", "match 0 3|2,2");
    check("(a?)*", "", "match 0 0|0,0");
}

unittest // captures keep the last completed value
{
    check("(a)|b", "b", "match 0 1|-");
    check("(a)+b", "aab", "match 0 3|1,2");
    check("(a|b)*", "abba", "match 0 4|3,4");
}

unittest // classes and escapes
{
    check("[a-c]+", "xxabcabcx", "match 2 8");
    check("[^a-c]+", "abcxyzabc", "match 3 6");
    check("[-a]+", "a-a", "match 0 3");
    check("[a-]+", "a-a", "match 0 3");
    check("[\\-x]+", "x-x", "match 0 3");
    check("[\\d\\s]+", "ab 12 cd", "match 2 6");
    check("\\w+", "  foo_1  ", "match 2 7");
    check("\\W+", "ab, cd", "match 2 4");
    check("\\D+", "12ab34", "match 2 4");
    check("\\S+", "  x  ", "match 2 3");
    check("\\.", "a.b", "match 1 2");
    check("\\ ", "a b", "match 1 2");
    check("[.]", "a.b", "match 1 2");
    check("[\\]]", "a]b", "match 1 2");
    check("[a^]+", "^a", "match 0 2");
}

unittest // backtracking into single-character loops
{
    check("a*ab", "aaab", "match 0 4");
    check("(a+)(a+)", "aaaa", "match 0 4|0,3|3,4");
    check("(a*)(a{2,3})", "aaaa", "match 0 4|0,2|2,4");
    check(".*(.)", "abc", "match 0 3|2,3");
    check("(x+x+)+y", "xxxxxxxxxxxxxxxxxxxx", "no");
}

unittest // start position is leftmost
{
    check("b+", "aabbb", "match 2 5");
    check("a*b", "aaaaac", "no");
    check("(a|aa)+c", "aaaaaaaaaaaaaaaaaaaaaaaab", "no");
}

unittest // long subjects need no deep native recursion
{
    import std.array : replicate;

    check(".*x", "a".replicate(10000) ~ "x", "match 0 10001");
    check("(a)*", "a".replicate(10000), "match 0 10000|9999,10000");
}

// ---- Matcher reuse ---------------------------------------------------------

unittest
{
    Matcher m;
    auto a = new Regex("(b)+");
    auto b = new Regex("(a)(b)(c)");
    auto r1 = a.search("abbb", m);
    assert(r1.matched && r1.begin == 1 && r1.end == 4 && r1.group(1) == Span(3, 4));
    auto r2 = b.search("xabc", m);
    assert(r2.matched && r2.group(3) == Span(3, 4));
    auto r3 = a.search("zzz", m);
    assert(!r3.matched);
    assert(a.groupCount == 1 && b.groupCount == 3);
    assert(a.matches("b") && !a.matches("a"));
}

// ---- parser ----------------------------------------------------------------

private bool rejects(string pattern)
{
    try
    {
        new Regex(pattern);
    }
    catch (RegexException)
        return true;
    return false;
}

unittest
{
    assert(rejects("(")); // unbalanced
    assert(rejects(")"));
    assert(rejects("*a")); // nothing to repeat
    assert(rejects("a**"));
    assert(rejects("^*"));
    assert(rejects("[a"));
    assert(rejects("[z-a]"));
    assert(rejects("a{2,1}"));
    assert(rejects("a{"));
    assert(rejects("\\"));
    assert(rejects("\\b"));
    assert(rejects("a+?"));
    assert(!rejects("a{0}"));
    assert(!rejects("[\\]a]"));
}

unittest
{
    auto p = parse("(a)(b(c))|d");
    assert(p.groupCount == 3);
    assert(p.root.kind == NodeKind.alt);
    assert(p.root.children.length == 2);

    auto q = parse("a{2,5}");
    auto rep = q.root.children[0];
    assert(rep.kind == NodeKind.repeat && rep.min == 2 && rep.max == 5);
    assert(parse("a{3,}").root.children[0].max == unbounded);
    assert(parse("a*").root.children[0].max == unbounded);
    assert(parse("a?").root.children[0].min == 0);
}

unittest // class parsing
{
    auto n = parse("[^a-c\\d]").root.children[0];
    assert(n.kind == NodeKind.set);
    assert(!n.set.contains('a') && !n.set.contains('b') && !n.set.contains('5'));
    assert(n.set.contains('d') && n.set.contains('z') && n.set.contains(' '));
}

// ---- character sets --------------------------------------------------------

unittest
{
    auto w = CharSet.word();
    assert(w.contains('a') && w.contains('Z') && w.contains('_') && w.contains('7'));
    assert(!w.contains('-') && !w.contains(' '));
    auto s = CharSet.space();
    assert(s.contains(' ') && s.contains('\t') && !s.contains('a'));
    auto d = CharSet.digits();
    d.invert();
    assert(!d.contains('3') && d.contains('a'));
    assert(CharSet.all().isFull && !CharSet.single('a').isFull);
}

// ---- analysis --------------------------------------------------------------

unittest
{
    assert(anchoredAtStart(parse("^abc").root));
    assert(anchoredAtStart(parse("^a|^b").root));
    assert(anchoredAtStart(parse("(^a)+").root));
    assert(!anchoredAtStart(parse("^a|b").root));
    assert(!anchoredAtStart(parse("(^a)*").root));
    assert(!anchoredAtStart(parse("a^").root));
}

unittest
{
    assert(nullable(parse("").root));
    assert(nullable(parse("a*").root));
    assert(nullable(parse("a{0}").root));
    assert(nullable(parse("^$").root));
    assert(nullable(parse("a|").root));
    assert(!nullable(parse("a+").root));
    assert(!nullable(parse("(a|b)c*").root));

    CharSet s;
    firstSet(parse("a*[bc]d").root, s);
    assert(s.contains('a') && s.contains('b') && s.contains('c'));
    assert(!s.contains('d'));
}

// ---- compiler --------------------------------------------------------------

private size_t countOps(ref const Program p, Op op)
{
    size_t n;
    foreach (i; p.code)
        if (i.op == op)
            ++n;
    return n;
}

unittest // single-character loops compile to one charLoop
{
    auto p = compile(parse(".*[a-z]+\\d{2,5}"));
    assert(countOps(p, Op.charLoop) == 3);
    assert(countOps(p, Op.split) == 0);
}

unittest // mark/check only for bodies that can match empty
{
    auto plain = compile(parse("(ab)*"));
    assert(countOps(plain, Op.mark) == 0 && countOps(plain, Op.check) == 0);
    auto empty = compile(parse("(a*)*"));
    assert(countOps(empty, Op.mark) == 1 && countOps(empty, Op.check) == 1);
}

unittest // x{0} emits nothing; counted quantifiers expand
{
    auto zero = compile(parse("(a){0}"));
    assert(zero.code.length == 1 && zero.code[0].op == Op.match);
    auto three = compile(parse("(ab){3}"));
    assert(countOps(three, Op.save) == 6);
}

unittest // start-position filters
{
    auto p = compile(parse("^ab"));
    assert(p.anchored);
    auto q = compile(parse("[xy]z"));
    assert(!q.anchored && !q.nullable && q.first.contains('x') && !q.first.contains('z'));
    assert(compile(parse("x*")).nullable);
}

// ---- batch protocol --------------------------------------------------------

private string batch(string input)
{
    OutputBuffer o;
    processBatch(cast(const(ubyte)[]) input, o);
    return cast(string) o.bytes.idup;
}

unittest
{
    assert(batch("1\na(b)?\n3\nab\nxa\nzzz\n") == "match 0 2|1,2\nmatch 1 2|-\nno\n");
}

unittest // strictly positional: empty / space-only / numeric-looking lines
{
    // empty pattern with two subjects (one empty, one spaces)
    assert(batch("1\n\n2\n\n  \n") == "match 0 0\nmatch 0 0\n");
    // pattern that looks like an integer; M = 0 for the first pattern
    assert(batch("2\n3\n0\n 1\n2\n 1\n1 \n") == "match 0 2\nno\n");
}

unittest
{
    assert(batch("2\n(a|ab)(c|bcd)(d*)\n1\nabcd\na*\n0\n") == "match 0 4|0,1|1,4|4,4\n");
    assert(batch("1\nx\n0\n") == "");
}

unittest // integer formatting
{
    OutputBuffer o;
    o.putInt(0);
    o.put(' ');
    o.putInt(7);
    o.put(' ');
    o.putInt(10);
    o.put(' ');
    o.putInt(4_000_000_000);
    assert(cast(const(char)[]) o.bytes == "0 7 10 4000000000");
}
