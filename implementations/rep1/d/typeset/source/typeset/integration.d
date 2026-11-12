/// End-to-end tests of the pipeline using a small synthetic font, so they
/// need no data files. (If `TYPESET_DATA` names the shipped data directory,
/// one extra test also runs against the real metrics.)
module typeset.integration;

version (unittest)
{
    import std.algorithm : canFind;
    import std.file : exists;
    import std.process : environment;

    import typeset;
    import typeset.hyphenation : PatternSet;
    import typeset.metrics : FaceSet, faceCount;

    private enum geometry = "page-width = 200pt\npage-height = 120pt\nmargin-top = 20pt\nmargin-bottom = 20pt\n"
        ~ "margin-left = 20pt\nmargin-right = 20pt\n";
    private enum smallPage = geometry ~ "par-indent = 0\n";

    private Resources syntheticResources()
    {
        // Every glyph advances 500 units; the space is 250/125/80.
        immutable cfm = "cfm 1\nface x\nascent 700\ndescent 200\nspace 250 125 80\nextra 100\ndefault 500\n";
        string[faceCount] sources;
        foreach (ref s; sources)
            s = cfm;
        auto r = new Resources;
        r.faces = FaceSet.fromSources(sources);
        r.english = PatternSet.parse("chp 1\nleft 2\nright 2\npattern a1b\n");
        r.minimal = PatternSet.parse("chp 1\nleft 2\nright 2\n");
        return r;
    }

    unittest
    {
        auto res = syntheticResources();
        auto r = typesetSources(res, "ab cd.\n", smallPage);
        assert(r.ok);
        assert(r.layout.toText() == "layout 1\npages 1\npage 1 1 200000 120000 20000 20000 160000 80000\n"
                ~ "  text body serif 10000 20000 27000 10000 \"ab\"\n"
                ~ "  text body serif 10000 32500 27000 15000 \"cd.\"\n");
        assert(r.report.lines == 1 && r.report.paragraphs == 1 && r.report.totalDemerits == 100);
    }

    unittest
    {
        auto res = syntheticResources();
        auto r = typesetSources(res, "@h1 Title\n{z|oops}\n", smallPage);
        assert(!r.ok);
        assert(r.errorText == "document.cdx:2:1: unknown-inline\n");
        r = typesetSources(res, "text\n", "margin-left = 20px\n");
        assert(r.errorText == "settings.cfg:1:15: bad-length\n");
    }

    unittest
    {
        // a paragraph longer than a page spills onto further pages
        auto res = syntheticResources();
        string text;
        foreach (i; 0 .. 400)
            text ~= "word ";
        auto r = typesetSources(res, text ~ "\n", smallPage);
        assert(r.ok && r.layout.pages.length > 1);
        assert(r.report.overfullLines == 0);
        assert(r.report.pages == r.layout.pages.length);
    }

    unittest
    {
        auto res = syntheticResources();
        auto r = typesetSources(res, "@toc\n@h1 Intro\nhello\n", smallPage);
        assert(r.ok);
        assert(r.report.frontPages == 1 && r.report.bodyPages == 1);
        assert(r.layout.pages[0].label == "i" && r.layout.pages[1].label == "1");
    }

    unittest
    {
        auto res = syntheticResources();
        auto r = typesetSources(res, "Delta{n|A short note.} gamma.\n", smallPage);
        assert(r.ok && r.report.footnotes == 1);
        const text = r.layout.toText();
        assert(text.canFind("rule footnote 20000 "));
        assert(text.canFind("\"short\""));
    }

    unittest
    {
        auto res = syntheticResources();
        auto r = typesetSources(res, "one\n@newpage\ntwo\n", smallPage ~ "header-center = {page}/{pages}\n");
        assert(r.ok && r.layout.pages.length == 2);
        assert(r.layout.toText().canFind("text header sans 9000"));
        assert(r.layout.toText().canFind("\"2/2\""));
    }

    unittest
    {
        auto r = typesetSources(syntheticResources(), "", null);
        assert(r.ok && r.layout.toText() == "layout 1\npages 0\n");
    }

    unittest
    {
        immutable dir = environment.get("TYPESET_DATA", "");
        if (dir.length == 0 || !exists(dir))
            return;
        auto res = Resources.load(dir);
        auto r = typesetSources(res, "The quick brown fox.\n", geometry);
        assert(r.ok);
        assert(r.layout.toText().canFind("text body serif 10000 38000 27310 15630 \"The\""));
        assert(r.report.totalDemerits == 100);
    }
}
