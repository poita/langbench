/**
 * Test-only module: a direct, recursive transcription of section 3 of the
 * specification, used to cross-check the compiled VM on random patterns.
 */
module regex.reference_test;

version (unittest):

import regex.ast;
import regex.parser;
import regex.regex;

private alias Cont = bool delegate(int);

private struct Ref
{
    const(ubyte)[] s;
    int[2][] caps; // [-1,-1] = unset, indexed by group

    bool m(Node n, int i, scope Cont k)
    {
        immutable len = cast(int) s.length;
        final switch (n.kind)
        {
        case NodeKind.literal: return i < len && s[i] == n.ch && k(i + 1);
        case NodeKind.any: return i < len && k(i + 1);
        case NodeKind.set: return i < len && n.set.contains(s[i]) && k(i + 1);
        case NodeKind.bol: return i == 0 && k(i);
        case NodeKind.eol: return i == len && k(i);
        case NodeKind.seq: return seq(n.children, i, k);
        case NodeKind.alt:
            foreach (b; n.children)
                if (m(b, i, k))
                    return true;
            return false;
        case NodeKind.group:
            return m(n.children[0], i, (int j) {
                auto old = caps[n.group];
                caps[n.group] = [i, j];
                if (k(j))
                    return true;
                caps[n.group] = old;
                return false;
            });
        case NodeKind.repeat:
            return rep(n, i, 0, k);
        }
    }

    bool seq(Node[] xs, int i, scope Cont k)
    {
        if (xs.length == 0)
            return k(i);
        return m(xs[0], i, (int j) => seq(xs[1 .. $], j, k));
    }

    bool rep(Node n, int i, int count, scope Cont k)
    {
        auto x = n.children[0];
        if (count < n.min)
            return m(x, i, (int j) => rep(n, j, count + 1, k));
        if (n.max != unbounded && count == n.max)
            return k(i);
        if (m(x, i, (int j) => (j == i) ? k(j) : rep(n, j, count + 1, k)))
            return true;
        return k(i);
    }
}

/// Reference search; returns the same `Match` shape as the engine.
Match refMatch(Parsed p, const(char)[] subject)
{
    Match res;
    immutable len = cast(int) subject.length;
    foreach (start; 0 .. len + 1)
    {
        Ref r;
        r.s = cast(const(ubyte)[]) subject;
        r.caps = new int[2][](p.groupCount + 1);
        foreach (ref c; r.caps)
            c = [-1, -1];
        int endPos;
        if (r.m(p.root, start, (int j) { endPos = j; return true; }))
        {
            res.matched = true;
            res.start = start;
            res.end = endPos;
            foreach (g; 1 .. p.groupCount + 1)
                res.captures ~= r.caps[g][0] < 0 ? Capture(false, 0, 0)
                    : Capture(true, r.caps[g][0], r.caps[g][1]);
            return res;
        }
    }
    return res;
}

// --- random pattern generation -------------------------------------------

private struct Gen
{
    uint state;

    uint next()
    {
        state = state * 1664525 + 1013904223;
        return state >> 8;
    }

    uint below(uint n) { return next() % n; }

    string atom(int depth)
    {
        switch (below(depth > 0 ? 12 : 9))
        {
        case 0: case 1: case 2: return "a";
        case 3: case 4: return "b";
        case 5: return "c";
        case 6: return ".";
        case 7: return ["[ab]", "[^a]", "\\d", "\\w", "[a-b]"][below(5)];
        case 8: return ["^", "$", "x", "\\."][below(4)];
        default: return "(" ~ regex(depth - 1) ~ ")";
        }
    }

    string piece(int depth)
    {
        auto a = atom(depth);
        if (a == "^" || a == "$")
            return a;
        switch (below(8))
        {
        case 0: return a ~ "*";
        case 1: return a ~ "+";
        case 2: return a ~ "?";
        case 3: return a ~ "{2}";
        case 4: return a ~ ["{0,2}", "{1,3}", "{2,}", "{0}"][below(4)];
        default: return a;
        }
    }

    string branch(int depth)
    {
        string r;
        foreach (_; 0 .. below(4))
            r ~= piece(depth);
        return r;
    }

    string regex(int depth)
    {
        string r = branch(depth);
        while (below(4) == 0)
            r ~= "|" ~ branch(depth);
        return r;
    }

    string subject()
    {
        string r;
        foreach (_; 0 .. below(9))
            r ~= "abc1x."[below(6)];
        return r;
    }
}

unittest
{
    auto gen = Gen(12345);
    foreach (iter; 0 .. 3000)
    {
        auto pat = gen.regex(3);
        auto parsed = parse(pat);
        auto re = new Regex(pat);
        foreach (_; 0 .. 6)
        {
            auto subj = gen.subject();
            auto want = refMatch(parsed, subj);
            auto got = re.match(subj);
            assert(want.matched == got.matched, "pattern " ~ pat ~ " subject " ~ subj);
            if (want.matched)
            {
                assert(want.start == got.start && want.end == got.end,
                    "span: pattern " ~ pat ~ " subject " ~ subj);
                assert(want.captures == got.captures,
                    "captures: pattern " ~ pat ~ " subject " ~ subj);
            }
        }
    }
}

// --- hand-written semantic cases ------------------------------------------

private void check(string pat, string subj, string expect)
{
    import regex.batch : formatMatch;
    char[] b;
    formatMatch(b, new Regex(pat).match(subj));
    assert(b == expect, "pattern '" ~ pat ~ "' on '" ~ subj ~ "': got '" ~ b.idup ~ "' want '" ~ expect ~ "'");
}

unittest
{
    check("a|ab", "ab", "match 0 1");
    check("(a*){3}", "", "match 0 0|0,0");
    check("(a|(b))+", "ba", "match 0 2|1,2|0,1");
    check("(a*)*b", "aab", "match 0 3|2,2");
    check("(a*)+", "b", "match 0 0|0,0");
    check("(a{0})", "a", "match 0 0|0,0");
    check("(a){0}b", "b", "match 0 1|-");
    check("a^b", "ab", "no");
    check("$", "abc", "match 3 3");
    check("^$", "", "match 0 0");
    check("x*$", "axx", "match 1 3");
    check("\\s\\S", "a b", "match 1 3");
    check("[\\w-]+", "ab-c d", "match 0 4");
    check("[a-c-e]", "-", "match 0 1");
    check("(a)|b", "b", "match 0 1|-");
    check("a{2,3}", "aaaa", "match 0 3");
    check("(a|b)*c", "ababc", "match 0 5|3,4");
    check("(a*)*", "aa", "match 0 2|2,2");
}

unittest
{
    // Long subjects need no native recursion.
    import std.array : replicate;
    auto s = "a".replicate(10000);
    auto re = new Regex("(.*)b|(a*)");
    auto m = re.match(s);
    assert(m.matched && m.end == 10000 && m.group(2).set && !m.group(1).set);
    // Pathological but bounded: exponential-looking pattern on a short subject.
    assert(!new Regex("^(a|aa)+c").match("a".replicate(20)).matched);
}
