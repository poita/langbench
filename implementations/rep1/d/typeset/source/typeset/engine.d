/**
 * The top-level pipeline: settings and document in, pages and report out.
 */
module typeset.engine;

import std.conv : to;
import std.file : exists, isFile, readText;
import std.path : buildPath;

import typeset.compose;
import typeset.errors;
import typeset.hlist;
import typeset.hyphenation;
import typeset.layout;
import typeset.line;
import typeset.markup;
import typeset.metrics;
import typeset.paginate;
import typeset.settings;
import typeset.units;
import typeset.vlist;

/// Font metrics and hyphenation patterns shared by all documents.
final class Resources
{
    FaceSet faces;
    PatternSet english, minimal;

    /// Loads `<dataDir>/faces/*.cfm` and `<dataDir>/hyphen/*.chp`.
    static Resources load(string dataDir)
    {
        auto r = new Resources;
        r.faces = FaceSet.load(dataDir);
        r.english = PatternSet.load(dataDir, PatternId.english);
        r.minimal = PatternSet.load(dataDir, PatternId.minimal);
        return r;
    }

    PatternSet patterns(PatternId id)
    {
        return id == PatternId.english ? english : minimal;
    }
}

/// The outcome of typesetting one document: either a layout and its report,
/// or the single error that made the input invalid.
struct Result
{
    bool ok;
    Diagnostic error; /// valid when `!ok`
    Layout layout; /// valid when `ok`
    Report report; /// valid when `ok`

    /// Contents of `error.txt` (including the newline).
    string errorText() const
    {
        return error.toString() ~ "\n";
    }
}

/// Typesets `documentSource` (the text of `document.cdx`) with the settings
/// in `settingsSource` (the text of `settings.cfg`, or null).
Result typesetSources(Resources res, string documentSource, string settingsSource = null)
{
    Result result;
    try
    {
        auto s = parseSettings(settingsSource);
        auto doc = parseDocument(documentSource);
        result = compose(res, s, doc);
        result.ok = true;
    }
    catch (TypesetError e)
    {
        result = Result.init;
        result.ok = false;
        result.error = e.diagnostic;
    }
    return result;
}

/// Reads `document.cdx` and optional `settings.cfg` from `inputDir`.
Result typesetDirectory(Resources res, string inputDir)
{
    immutable docPath = buildPath(inputDir, "document.cdx");
    if (!exists(docPath) || !isFile(docPath))
    {
        Result r;
        r.error = Diagnostic("-", 0, 0, "missing-document");
        return r;
    }
    immutable setPath = buildPath(inputDir, "settings.cfg");
    string settings = null;
    if (exists(setPath) && isFile(setPath))
        settings = readText(setPath);
    return typesetSources(res, readText(docPath), settings);
}

private Result compose(Resources res, ref const Settings s, Document doc)
{
    auto composer = new Composer(s, res.faces, res.patterns(s.hyphenPatterns), doc);
    composer.composeBody();

    long splitLines = 0;
    PageSource bodySrc;
    bodySrc.items = composer.body_.items;
    bodySrc.lines = composer.lines;
    bodySrc.rows = composer.rows;
    bodySrc.figures = composer.figures;
    bodySrc.noteLines = composer.noteLines;
    auto bodyPages = paginate(bodySrc, s, splitLines);

    foreach (pi, ref p; bodyPages)
        foreach (id; p.headingStarts)
            composer.headings[id].page = cast(int) pi + 1;

    PageResult[] frontPages;
    if (doc.toc !is null)
    {
        string[] labels;
        foreach (ref h; composer.headings)
            labels ~= (s.pageStart + h.page - 1).to!string;
        auto tocList = composer.composeToc(doc.toc, labels);
        PageSource tocSrc;
        tocSrc.items = tocList.items;
        tocSrc.lines = composer.lines;
        tocSrc.rows = composer.rows;
        long ignored = 0;
        frontPages = paginate(tocSrc, s, ignored);
    }

    // assemble
    Layout layout;
    layout.pageWidth = s.pageWidth;
    layout.pageHeight = s.pageHeight;
    layout.bodyX = s.bodyX;
    layout.bodyY = s.bodyY;
    layout.bodyWidth = s.bodyWidth;
    layout.bodyHeight = s.bodyHeight;

    auto env = BuildEnv(res.faces, &s, res.patterns(s.hyphenPatterns));
    foreach (m, ref p; frontPages)
    {
        Page page;
        page.label = roman(cast(long) m + 1);
        page.items = p.items;
        addHeaderFooter(page, env, s, doc, cast(long) m + 1, bodyPages.length, null, null);
        layout.pages ~= page;
    }
    dstring chapter, section;
    foreach (m, ref p; bodyPages)
    {
        foreach (id; p.headingStarts)
        {
            const h = composer.headings[id];
            dstring text = h.number.length ? h.number.to!dstring ~ " "d ~ h.plain : h.plain;
            if (h.level == 1)
                chapter = text;
            else if (h.level == 2)
                section = text;
        }
        immutable number = s.pageStart + cast(long) m;
        Page page;
        page.label = number.to!string;
        page.items = p.items;
        addHeaderFooter(page, env, s, doc, number, bodyPages.length, chapter, section);
        layout.pages ~= page;
    }
    layout.sortItems();

    Report r;
    r.pages = layout.pages.length;
    r.frontPages = frontPages.length;
    r.bodyPages = bodyPages.length;
    r.lines = composer.stats.lines;
    r.paragraphs = composer.stats.paragraphs;
    r.headings = composer.stats.headings;
    r.tables = composer.stats.tables;
    r.figures = composer.stats.figures;
    r.footnotes = composer.stats.footnotes;
    r.footnoteSplitLines = splitLines;
    r.hyphenatedLines = composer.stats.hyphenatedLines;
    r.overfullLines = composer.stats.overfullLines;
    r.emergencyLists = composer.stats.emergencyLists;
    r.totalDemerits = composer.stats.totalDemerits;

    Result result;
    result.layout = layout;
    result.report = r;
    return result;
}

private dstring substitute(const Template t, ref const Settings s, Document doc, string label, size_t bodyPages,
    dstring chapter, dstring section)
{
    dstring r;
    foreach (part; t)
    {
        if (!part.isPlaceholder)
        {
            r ~= part.literal;
            continue;
        }
        final switch (part.placeholder)
        {
        case Placeholder.page:
            r ~= label.to!dstring;
            break;
        case Placeholder.pages:
            r ~= bodyPages.to!dstring;
            break;
        case Placeholder.title:
            r ~= doc.title;
            break;
        case Placeholder.author:
            r ~= doc.author;
            break;
        case Placeholder.date:
            r ~= doc.date;
            break;
        case Placeholder.chapter:
            r ~= chapter;
            break;
        case Placeholder.section:
            r ~= section;
            break;
        }
    }
    return r;
}

private void addHeaderFooter(ref Page page, ref BuildEnv env, ref const Settings s, Document doc, long number,
    size_t bodyPages, dstring chapter, dstring section)
{
    immutable even = number % 2 == 0;
    const(Template)[6] slots = even
        ? [s.headerLeftEven, s.headerCenterEven, s.headerRightEven, s.footerLeftEven, s.footerCenterEven,
            s.footerRightEven] : [s.headerLeft, s.headerCenter, s.headerRight, s.footerLeft, s.footerCenter,
            s.footerRight];
    foreach (k, ref t; slots)
    {
        if (t.length == 0)
            continue;
        const text = substitute(t, s, doc, page.label, bodyPages, chapter, section);
        auto style = ListStyle(s.headerFont, false, false, s.headerSize, true, false);
        auto items = buildList(null, literalTokens(text), style, env);
        long w = 0;
        bool any = false;
        foreach (ref it; items)
        {
            if (it.kind == Item.Kind.box)
            {
                w += it.width;
                any = true;
            }
            else if (it.kind == Item.Kind.glue)
                w += it.width;
        }
        if (!any)
            continue;
        long x;
        immutable col = k % 3;
        if (col == 0)
            x = s.bodyX;
        else if (col == 1)
            x = s.bodyX + fdiv(s.bodyWidth - w, 2);
        else
            x = s.bodyX + s.bodyWidth - w;
        immutable header = k < 3;
        foreach (ref it; items)
        {
            if (it.kind == Item.Kind.box)
            {
                if (!it.rigid)
                {
                    PlacedItem p;
                    p.region = header ? Region.header : Region.footer;
                    p.kind = ItemKind.text;
                    p.face = faceNames[it.face];
                    p.size = it.size;
                    p.x = x;
                    p.y = header ? s.headerBaseline : s.footerBaseline;
                    p.width = it.width;
                    p.text = it.text.to!string;
                    page.items ~= p;
                }
                x += it.width;
            }
            else if (it.kind == Item.Kind.glue)
                x += it.width;
        }
    }
}
