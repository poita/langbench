/// Shared fixtures for the unit tests: a synthetic font set and pattern sets
/// held in memory, so the tests do not depend on any data files.
module tests.support;

import typeset;

/// A face in which every glyph is 500 units wide and `A` followed by `V` kerns by -100.
string syntheticFace(string name, int space = 250, int stretch = 125, int shrink = 80, int extra = 100)
{
    import std.format : format;

    string t = "cfm 1\nface " ~ name ~ "\nascent 800\ndescent 200\n";
    t ~= format("space %d %d %d\nextra %d\ndefault 500\n", space, stretch, shrink, extra);
    foreach (c; 33 .. 127)
        t ~= format("glyph %d 500\n", c);
    t ~= "glyph 32 250\nkern 65 86 -100\n";
    return t;
}

/// The nine synthetic faces.
FontSet syntheticFonts()
{
    string[] texts;
    foreach (n; faceNames)
        texts ~= syntheticFace(n);
    return FontSet.fromTexts(texts);
}

/// A tiny English-like pattern set.
enum patternText = "chp 1\nleft 2\nright 3\npattern n1t\npattern t1t\npattern 3ing\npattern n1g\n"
    ~ "exception al-go-rithm\nexception through\n";

/// In-memory data source for end-to-end tests.
final class MemoryData : DataSource
{
    FontSet fonts()
    {
        return syntheticFonts();
    }

    PatternSet patterns(PatternsId id)
    {
        return PatternSet.parse(patternText);
    }
}

/// A small-page settings file (200pt x 120pt, 20pt margins).
enum smallPage = "page-width = 200pt\npage-height = 120pt\nmargin-top = 20pt\n"
    ~ "margin-bottom = 20pt\nmargin-left = 20pt\nmargin-right = 20pt\n";

/// Typesets a document with optional settings text on the synthetic data.
Result run(string document, string settings = null)
{
    Input input;
    input.document = document;
    input.hasDocument = true;
    input.settings = settings;
    input.hasSettings = settings !is null;
    return typesetDocument(input, new MemoryData);
}
