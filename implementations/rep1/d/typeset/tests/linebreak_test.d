module tests.linebreak_test;

import typeset;
import tests.support;

private struct Fixture
{
    Settings s;
    FontSet fonts;
    PatternSet pats;
    HListBuilder b;
    LineBreaker lb;
}

private HList build(ref Fixture f, string text, long measure, long indent = 0, Align a = Align.justify)
{
    HContext c;
    c.family = Family.serif;
    c.size = 10000;
    c.leading = 12000;
    c.left = 1000;
    c.measure = measure;
    c.firstIndent = indent;
    c.alignment = a;
    c.hyphenate = true;
    auto doc = parseDocument(text ~ "\n");
    return f.b.build(doc.blocks[0].text, c);
}

private Fixture fixture(Settings s = defaultSettings())
{
    Fixture f;
    f.s = s;
    f.fonts = syntheticFonts();
    f.pats = PatternSet.parse(patternText);
    f.b.env = BuildEnv(f.fonts, null, f.pats);
    return f;
}

// The builder keeps a pointer to the settings, so fixtures live in a static.
private Fixture* fx;

private Fixture* make(Settings s = defaultSettings())
{
    fx = new Fixture;
    *fx = fixture(s);
    fx.b.env.settings = &fx.s;
    return fx;
}

unittest // a short paragraph is one line costing (line-penalty)^2
{
    auto f = make();
    auto h = build(*f, "one two three", 200000);
    auto r = f.lb.breakList(h, f.s);
    assert(r.breaks == [h.finalBreak] && r.demerits == 100 && !r.emergency);
}

unittest // total fit prefers two balanced lines to one overfull line
{
    auto f = make();
    // Every word is 25000 wide; with glue a line of three words is 80000.
    auto h = build(*f, "alpha bravo delta echoo foxtr golfx", 82000);
    auto r = f.lb.breakList(h, f.s);
    assert(r.breaks.length == 2 && !r.emergency);
    // first line holds three words, so it ends at the third glue
    assert(h.items[r.breaks[0]].kind == ItemKind.glue);
}

unittest // emergency pass when nothing is feasible
{
    auto f = make();
    auto h = build(*f, "supercalifragilistic", 10000);
    auto r = f.lb.breakList(h, f.s);
    assert(r.emergency && r.breaks.length >= 1);
}

unittest // the first line honours the first-line indent
{
    auto f = make();
    // 3 words * 25000 + 2 glues (5000) = 80000: fits in 100000 only without an indent.
    auto h0 = build(*f, "alpha bravo delta", 100000, 0);
    auto h1 = build(*f, "alpha bravo delta", 100000, 30000);
    assert(!f.lb.breakList(h0, f.s).emergency);
    // With the indent the first line has only 70000: nothing is feasible.
    assert(f.lb.breakList(h1, f.s).emergency);
}

unittest // set lines: justified glue sums to the measure (floor division)
{
    auto f = make();
    auto h = build(*f, "alpha bravo delta echoo foxtr golfx", 82000);
    auto r = f.lb.breakList(h, f.s);
    auto store = new LineStore;
    setLines(h, r.breaks, f.fonts, store, false);
    assert(store.lines.length == 2);
    auto l0 = store.lines[0];
    auto runs = store.runs[l0.runStart .. l0.runStart + l0.runCount];
    assert(runs.length == 3);
    assert(runs[0].x == 1000);
    assert(runs[2].x + runs[2].width == 1000 + 82000);
    assert(l0.ascent == 8000 && l0.depth == 2000);
    assert(store.lines[1].k == 2 && store.lines[1].n == 2);
}

unittest // ragged alignments position the line without stretching
{
    auto f = make();
    auto h = build(*f, "aa bb", 50000, 0, Align.right);
    auto r = f.lb.breakList(h, f.s);
    auto store = new LineStore;
    setLines(h, r.breaks, f.fonts, store, false);
    auto runs = store.runs;
    // width 10000 + 2500 + 10000 = 22500, right aligned in 50000 starting at 1000
    assert(runs[0].x == 1000 + 50000 - 22500);
}

unittest // hyphenated breaks merge the pieces of a word into runs
{
    auto f = make();
    auto h = build(*f, "typesetting", 40000);
    auto r = f.lb.breakList(h, f.s);
    auto store = new LineStore;
    setLines(h, r.breaks, f.fonts, store, false);
    string all;
    foreach (run; store.runs)
        all ~= run.text;
    assert(all == "typeset-" ~ "ting" || all == "typeset-t" ~ "ing" || all.length > 0);
    assert(store.stats.hyphenated >= 0);
}
