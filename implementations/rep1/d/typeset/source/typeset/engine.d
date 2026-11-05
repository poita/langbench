/// The top-level pipeline: validate settings and document, lay the document
/// out, paginate, and produce `layout.txt` / `report.txt` or `error.txt`.
module typeset.engine;

import std.file : exists, isFile, mkdirRecurse, readText, write;
import std.path : buildPath;
import typeset.arith;
import typeset.errors;
import typeset.fonts;
import typeset.hyphen;
import typeset.layout;
import typeset.markup;
import typeset.output;
import typeset.page;
import typeset.settings;

/// The files produced for one run. Exactly one of `error` or the pair
/// `layout`/`report` is set.
struct Result
{
    bool ok; /// whether the input was valid
    string error; /// contents of `error.txt` (when `!ok`)
    string layout; /// contents of `layout.txt`
    string report; /// contents of `report.txt`
}

/// Provides the font and pattern data, loaded on demand.
interface DataSource
{
    /// The nine faces.
    FontSet fonts();
    /// A pattern set.
    PatternSet patterns(PatternsId id);
}

/// Loads data from a directory with `faces/` and `hyphen/` subdirectories.
final class DirectoryData : DataSource
{
    private string dir;
    private FontSet fs;
    private PatternSet[2] ps;

    this(string dataDir)
    {
        dir = dataDir;
    }

    FontSet fonts()
    {
        if (fs is null)
            fs = FontSet.load(dir);
        return fs;
    }

    PatternSet patterns(PatternsId id)
    {
        if (ps[id] is null)
            ps[id] = PatternSet.load(dir, id);
        return ps[id];
    }
}

/// The contents of an input directory.
struct Input
{
    string document; /// text of `document.cdx`
    bool hasDocument; /// whether `document.cdx` exists
    string settings; /// text of `settings.cfg`
    bool hasSettings; /// whether `settings.cfg` exists
}

/// Typesets a document: validates the inputs, lays the document out and
/// returns the output files' contents (or the error report).
Result typesetDocument(const Input input, DataSource data)
{
    Result res;
    if (!input.hasDocument)
    {
        res.error = Diagnostic("-", 0, 0, ErrorCode.missingDocument).toString() ~ "\n";
        return res;
    }
    Settings settings;
    Document doc;
    try
    {
        settings = input.hasSettings ? parseSettings(input.settings) : defaultSettings();
        doc = parseDocument(input.document);
    }
    catch (TypesetError e)
    {
        res.error = e.diag.toString() ~ "\n";
        return res;
    }

    auto fonts = data.fonts();
    auto patterns = data.patterns(settings.hyphenPatterns);
    auto layout = new Layout(&settings, fonts, patterns, doc);
    layout.layoutBody();
    auto pager = new Paginator(layout);
    auto body_ = pager.paginate(layout.items, true);
    PageInfo[] front;
    if (doc.hasToc)
    {
        immutable pageStart = settings.pageStart;
        auto tocItems = layout.layoutToc((int p) => toDecimal(pageStart + p - 1));
        front = pager.paginate(tocItems, false);
    }

    // Output.
    Buf lay;
    lay.put("layout 1\npages ");
    lay.putInt(front.length + body_.length);
    lay.put('\n');
    int index = 0;
    foreach (ref group; [front, body_])
        foreach (ref pi; group)
        {
            pager.renderHeaderFooter(pi, body_.length);
            ++index;
            lay.put("page ");
            lay.putInt(index);
            lay.put(' ');
            lay.put(pi.label);
            foreach (v; [settings.pageWidth, settings.pageHeight, settings.bodyX, settings.bodyY,
                    settings.bodyWidth, settings.bodyHeight])
            {
                lay.put(' ');
                lay.putInt(v);
            }
            lay.put('\n');
            pi.page.render(lay);
        }
    res.layout = lay[].idup;

    auto st = layout.store.stats;
    Buf rep;
    void kv(string k, long v)
    {
        rep.put(k);
        rep.put(' ');
        rep.putInt(v);
        rep.put('\n');
    }

    rep.put("report 1\n");
    kv("pages", front.length + body_.length);
    kv("front-pages", front.length);
    kv("body-pages", body_.length);
    kv("lines", st.lines);
    kv("paragraphs", doc.paragraphs);
    kv("headings", doc.headings);
    kv("tables", doc.tables);
    kv("figures", doc.figures);
    kv("footnotes", doc.footnotes.length);
    kv("footnote-split-lines", st.splitLines);
    kv("hyphenated-lines", st.hyphenated);
    kv("overfull-lines", st.overfull);
    kv("emergency-lists", st.emergency);
    kv("total-demerits", st.demerits);
    res.report = rep[].idup;
    res.ok = true;
    return res;
}

/// Runs the engine on an input directory and writes the result files into
/// `outputDir` (created if missing). `dataDir` holds `faces/` and `hyphen/`.
void typesetDirectory(string inputDir, string outputDir, string dataDir)
{
    immutable docPath = buildPath(inputDir, "document.cdx");
    immutable cfgPath = buildPath(inputDir, "settings.cfg");
    Input input;
    if (exists(docPath) && isFile(docPath))
    {
        input.document = readText(docPath);
        input.hasDocument = true;
    }
    if (exists(cfgPath) && isFile(cfgPath))
    {
        input.settings = readText(cfgPath);
        input.hasSettings = true;
    }
    auto res = typesetDocument(input, new DirectoryData(dataDir));
    mkdirRecurse(outputDir);
    if (res.ok)
    {
        write(buildPath(outputDir, "layout.txt"), res.layout);
        write(buildPath(outputDir, "report.txt"), res.report);
    }
    else
        write(buildPath(outputDir, "error.txt"), res.error);
}
