module tests.engine_test;

import std.algorithm : canFind;
import std.string : splitLines;
import typeset;
import tests.support;

private string[] itemLines(string layout)
{
    string[] r;
    foreach (l; splitLines(layout))
        if (l.length > 2 && l[0 .. 2] == "  ")
            r ~= l[2 .. $];
    return r;
}

unittest // a missing document is reported, not thrown
{
    Input input;
    auto r = typesetDocument(input, new MemoryData);
    assert(!r.ok && r.error == "-:0:0: missing-document\n");
}

unittest // an empty document produces no pages
{
    auto r = run("");
    assert(r.ok && r.layout == "layout 1\npages 0\n");
    assert(r.report.canFind("pages 0\n") && r.report.canFind("total-demerits 0\n"));
}

unittest // one paragraph on one line (cf. Example 5, synthetic font)
{
    auto r = run("The quick brown fox.\n", smallPage);
    assert(r.ok);
    assert(itemLines(r.layout) == [
        `text body serif 10000 38000 28000 15000 "The"`,
        `text body serif 10000 55500 28000 25000 "quick"`,
        `text body serif 10000 83000 28000 25000 "brown"`,
        `text body serif 10000 110500 28000 20000 "fox."`,
    ]);
    assert(r.layout.canFind("page 1 1 200000 120000 20000 20000 160000 80000\n"));
    assert(r.report.canFind("lines 1\n") && r.report.canFind("paragraphs 1\n"));
    assert(r.report.canFind("total-demerits 100\n"));
}

unittest // invalid input yields only an error
{
    auto r = run("{z|x}\n", smallPage);
    assert(!r.ok && r.error == "document.cdx:1:1: unknown-inline\n" && r.layout.length == 0);
    r = run("x\n", "page-width = nope\n");
    assert(!r.ok && r.error == "settings.cfg:1:14: bad-length\n");
}

unittest // pages: an explicit page break starts a new page and numbering follows page-start
{
    auto r = run("One.\n\n@newpage\nTwo.\n", smallPage ~ "page-start = 7\n");
    assert(r.ok);
    assert(r.layout.canFind("pages 2\n"));
    assert(r.layout.canFind("page 1 7 ") && r.layout.canFind("page 2 8 "));
}

unittest // a table of contents adds roman-numbered front pages
{
    auto r = run("@toc\n@h1 Intro\nText.\n", smallPage);
    assert(r.ok);
    assert(r.report.canFind("front-pages 1\n") && r.report.canFind("body-pages 1\n"));
    assert(r.layout.canFind("page 1 i "));
    assert(r.layout.canFind(`"Contents"`));
}

unittest // footnotes land in the footnote region with their separator rule
{
    auto r = run("Word{n|Note.} more.\n", smallPage);
    assert(r.ok);
    bool rule, mark;
    foreach (l; itemLines(r.layout))
    {
        rule |= l.canFind("rule footnote");
        mark |= l.canFind(`text footnote serif 6000`) && l.canFind(`"1"`);
    }
    assert(rule && mark);
    assert(r.report.canFind("footnotes 1\n"));
}

unittest // figures float to the following page
{
    auto r = run("@fig height=20pt\nCap.\n@end\nBody.\n", smallPage);
    assert(r.ok && r.layout.canFind("pages 2\n"));
    assert(r.layout.canFind("box float 20000 20000 160000 20000"));
    assert(r.report.canFind("figures 1\n"));
}

unittest // running headers substitute placeholders
{
    auto r = run("@doc\ntitle = T\n@end\nBody.\n", smallPage ~ "header-center = {title}-{page}\nheader-baseline = 10pt\n");
    assert(r.ok);
    bool found;
    foreach (l; itemLines(r.layout))
        found |= l.canFind("text header sans 9000") && l.canFind(`"T-1"`);
    assert(found);
}
