module tests.hlist_test;

import typeset;
import tests.support;

private HList buildFor(string text, HContext ctx, Settings s = defaultSettings())
{
    static Settings keep;
    keep = s;
    auto env = BuildEnv(syntheticFonts(), &keep, PatternSet.parse(patternText));
    HListBuilder b;
    b.env = env;
    auto doc = parseDocument(text ~ "\n");
    return b.build(doc.blocks[0].text, ctx);
}

private HContext bodyContext()
{
    HContext c;
    c.family = Family.serif;
    c.size = 10000;
    c.leading = 12000;
    c.left = 0;
    c.measure = 100000;
    c.alignment = Align.justify;
    c.hyphenate = true;
    return c;
}

unittest // boxes, glue and the three closing items
{
    auto h = buildFor("ab cd", bodyContext());
    assert(h.items.length == 6);
    assert(h.items[0].kind == ItemKind.box && h.items[0].width == 10000);
    assert(h.items[1].kind == ItemKind.glue && h.items[1].width == 2500
            && h.items[1].a == 1250 && h.items[1].b == 800);
    assert(h.items[2].kind == ItemKind.box);
    assert(h.items[3].kind == ItemKind.penalty && h.items[3].a == 10000);
    assert(h.items[4].kind == ItemKind.glue && h.items[4].flag);
    assert(h.items[5].kind == ItemKind.penalty && h.items[5].a == -10000);
    assert(h.breakpoints == [1, 5]);
}

unittest // an empty text still has the final breakpoint
{
    HContext c = bodyContext();
    Inline empty;
    auto st = new Settings;
    *st = defaultSettings();
    auto env = BuildEnv(syntheticFonts(), st, null);
    HListBuilder b;
    b.env = env;
    auto h = b.build(empty, c);
    assert(h.items.length == 3 && h.breakpoints == [2]);
}

unittest // hyphenation points become flagged penalties with a pre-break hyphen
{
    auto h = buildFor("typesetting", bodyContext());
    assert(h.items.length == 5 + 3);
    assert(h.items[0].width == 35000 && h.items[2].width == 5000 && h.items[4].width == 15000);
    foreach (i; [1, 3])
    {
        assert(h.items[i].kind == ItemKind.penalty && h.items[i].flag && h.items[i].hasPre);
        assert(h.items[i].a == 50 && h.items[i].width == 5000);
    }
    // all three boxes belong to one fragment
    assert(h.items[0].frag == h.items[2].frag && h.items[2].frag == h.items[4].frag);
}

unittest // explicit discretionary points replace Liang's algorithm
{
    auto h = buildFor("typesetting\\-x", bodyContext());
    // the only point is the explicit one, before the final x
    size_t pens;
    foreach (it; h.items[0 .. $ - 3])
        pens += it.kind == ItemKind.penalty;
    assert(pens == 1);
}

unittest // no hyphenation in mono or when switched off
{
    auto h = buildFor("{m|typesetting}", bodyContext());
    assert(h.items.length == 1 + 3);
    auto s = defaultSettings();
    s.hyphenate = false;
    h = buildFor("typesetting", bodyContext(), s);
    assert(h.items.length == 1 + 3);
}

unittest // the sentence rule gives extra space after a period, not after an initial
{
    auto h = buildFor("end. Next J. Smith", bodyContext());
    // glues at items 1 and 3 and 5
    assert(h.items[1].kind == ItemKind.glue && h.items[1].width == 2500 + 1000);
    assert(h.items[1].a == 1870); // scale(125 + 125 div 2, 10000)
    assert(h.items[3].width == 2500); // "Next" is not a sentence end
    assert(h.items[5].width == 2500); // "J." follows an uppercase letter
}

unittest // ragged alignments replace stretch and shrink
{
    auto c = bodyContext();
    c.alignment = Align.left;
    auto h = buildFor("a b", c);
    assert(h.items[1].a == 3 * 2500 && h.items[1].b == 0);
}

unittest // style tags change face, size and rigid spaces are boxes
{
    auto h = buildFor("a~{+|b}", bodyContext());
    assert(h.items[1].kind == ItemKind.box && h.items[1].face == noFace && h.items[1].width == 2500);
    assert(h.items[2].size == 12000);
}

unittest // prefix sums and line widths
{
    auto h = buildFor("ab cd ef", bodyContext());
    assert(h.naturalWidth == 10000 * 3 + 2 * 2500);
    assert(h.lineWidth(-1, 3) == 10000 + 2500 + 10000);
    // leading glue is dropped: the line after breakpoint 1 starts at item 2
    assert(h.lineWidth(1, 3) == 10000);
}
