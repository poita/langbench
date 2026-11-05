/// The layout settings: the `settings.cfg` parser, the 126-key table with
/// defaults and ranges, and the derived page geometry.
module typeset.settings;

import typeset.arith : fdiv;
import typeset.errors;
import typeset.fonts : Family;
import typeset.hyphen : PatternsId;
import typeset.values;

/// Text alignment of a horizontal list.
enum Align : ubyte
{
    justify,
    left,
    right,
    center,
}

/// A placeholder usable in header/footer text.
enum Placeholder : ubyte
{
    page,
    pages,
    title,
    author,
    date,
    chapter,
    section,
}

/// One piece of a header/footer template: literal text or a placeholder.
struct TextPart
{
    bool isPlaceholder; ///
    Placeholder placeholder; ///
    string text; /// the literal text (when not a placeholder)
}

/// A parsed `text` setting value.
alias Template = TextPart[];

/// Renders a template that contains no placeholders back to plain text.
string literalText(const Template t) pure @safe
{
    string r;
    foreach (p; t)
        r ~= p.text;
    return r;
}

/// All layout settings with their defaults. Lengths are in millipoints.
struct Settings
{

    // Page geometry
    long pageWidth = 612000; /// `page-width`
    long pageHeight = 792000; /// `page-height`
    long marginTop = 72000; /// `margin-top`
    long marginBottom = 72000; /// `margin-bottom`
    long marginLeft = 72000; /// `margin-left`
    long marginRight = 72000; /// `margin-right`
    long headerBaseline = 36000; /// `header-baseline`
    long footerBaseline = 0; /// `footer-baseline`
    long pageStart = 1; /// `page-start`

    // Body text
    Family bodyFont = Family.serif; /// `body-font`
    long bodySize = 10000; /// `body-size`
    long leading = 12000; /// `leading`
    long lineSkip = 1000; /// `line-skip`
    Align textAlign = Align.justify; /// `align`
    long parIndent = 18000; /// `par-indent`
    long parSpace = 0; /// `par-space`

    // Line breaking
    long tolerance = 1000; /// `tolerance`
    long linePenalty = 10; /// `line-penalty`
    long hyphenPenalty = 50; /// `hyphen-penalty`
    long exHyphenPenalty = 50; /// `ex-hyphen-penalty`
    long adjDemerits = 10000; /// `adj-demerits`
    long doubleHyphenDemerits = 10000; /// `double-hyphen-demerits`
    long finalHyphenDemerits = 5000; /// `final-hyphen-demerits`
    long raggedStretch = 3; /// `ragged-stretch`
    bool hyphenate = true; /// `hyphenate`
    PatternsId hyphenPatterns = PatternsId.english; /// `hyphen-patterns`

    // Headings
    Family headingFont = Family.sans; /// `heading-font`
    bool headingBold = true; /// `heading-bold`
    bool headingItalic = false; /// `heading-italic`
    Align headingAlign = Align.left; /// `heading-align`
    bool headingNumber = true; /// `heading-number`
    long headingNumberGap = 6000; /// `heading-number-gap`
    bool h1Newpage = false; /// `h1-newpage`

    // Lists, quotes and preformatted text
    long listIndent = 18000; /// `list-indent`
    long listMarkerGap = 4000; /// `list-marker-gap`
    long listSpace = 6000; /// `list-space`
    long listItemSpace = 0; /// `list-item-space`
    long quoteIndent = 18000; /// `quote-indent`
    long quoteSpace = 6000; /// `quote-space`
    Family preFont = Family.mono; /// `pre-font`
    long preSize = 9000; /// `pre-size`
    long preLeading = 11000; /// `pre-leading`
    long preIndent = 0; /// `pre-indent`
    long preSpace = 6000; /// `pre-space`

    // Tables and rules
    long tableColGap = 8000; /// `table-col-gap`
    long tableRowSpace = 2000; /// `table-row-space`
    long tableRuleSpace = 2000; /// `table-rule-space`
    long tableRuleThickness = 400; /// `table-rule-thickness`
    long tableSpace = 6000; /// `table-space`
    long tableLeading = 12000; /// `table-leading`
    long ruleThickness = 500; /// `rule-thickness`
    long ruleSpace = 6000; /// `rule-space`

    // Footnotes
    Family footnoteFont = Family.serif; /// `footnote-font`
    long footnoteSize = 8000; /// `footnote-size`
    long footnoteLeading = 10000; /// `footnote-leading`
    long footnoteIndent = 10000; /// `footnote-indent`
    long footnoteMarkGap = 2000; /// `footnote-mark-gap`
    long footnoteMarkSize = 6000; /// `footnote-mark-size`
    long footnoteMarkRaise = 2000; /// `footnote-mark-raise`
    long footnoteItemSpace = 2000; /// `footnote-item-space`
    long footnoteRuleWidth = 120000; /// `footnote-rule-width`
    long footnoteRuleThickness = 400; /// `footnote-rule-thickness`
    long footnoteSpaceBefore = 6000; /// `footnote-space-before`
    long footnoteSpaceAfter = 3000; /// `footnote-space-after`
    long footnoteMinSplit = 1; /// `footnote-min-split`
    long footnoteMaxHeight = 0; /// `footnote-max-height`
    long markSize = 7000; /// `mark-size`
    long markRaise = 3000; /// `mark-raise`

    // Figures
    long figureWidth = 0; /// `figure-width`
    bool figureFrame = true; /// `figure-frame`
    Family figureCaptionFont = Family.serif; /// `figure-caption-font`
    long figureCaptionSize = 9000; /// `figure-caption-size`
    long figureCaptionLeading = 11000; /// `figure-caption-leading`
    Align figureCaptionAlign = Align.center; /// `figure-caption-align`
    long figureCaptionSpace = 4000; /// `figure-caption-space`
    Template figureCaptionPrefix; /// `figure-caption-prefix`
    long figureCaptionGap = 4000; /// `figure-caption-gap`
    long floatSpaceAfter = 12000; /// `float-space-after`
    long floatMinBody = 24000; /// `float-min-body`

    // Page breaking
    long widows = 2; /// `widows`
    long orphans = 2; /// `orphans`
    bool keepWithNext = true; /// `keep-with-next`

    // Table of contents
    long tocDepth = 2; /// `toc-depth`
    Family tocFont = Family.serif; /// `toc-font`
    long tocSize = 10000; /// `toc-size`
    long tocLeading = 14000; /// `toc-leading`
    long tocIndent = 18000; /// `toc-indent`
    long tocNumberGap = 6000; /// `toc-number-gap`
    long tocReserve = 30000; /// `toc-reserve`
    Template tocLeader; /// `toc-leader`
    long tocLeaderGap = 3000; /// `toc-leader-gap`
    long tocEntrySpace = 0; /// `toc-entry-space`
    Template tocTitle; /// `toc-title`
    Family tocTitleFont = Family.sans; /// `toc-title-font`
    long tocTitleSize = 20000; /// `toc-title-size`
    long tocTitleSpaceAfter = 12000; /// `toc-title-space-after`

    // Running headers and footers
    Family headerFont = Family.sans; /// `header-font`
    long headerSize = 9000; /// `header-size`
    Template headerLeft; /// `header-left`
    Template headerCenter; /// `header-center`
    Template headerRight; /// `header-right`
    Template footerLeft; /// `footer-left`
    Template footerCenter; /// `footer-center`
    Template footerRight; /// `footer-right`
    Template headerLeftEven; /// `header-left-even`
    Template headerCenterEven; /// `header-center-even`
    Template headerRightEven; /// `header-right-even`
    Template footerLeftEven; /// `footer-left-even`
    Template footerCenterEven; /// `footer-center-even`
    Template footerRightEven; /// `footer-right-even`
    /// `hN-size`, `hN-leading`, `hN-space-before`, `hN-space-after` for N = 1..4
    long[4] hSize = [20000, 14000, 12000, 11000];
    long[4] hLeading = [24000, 17000, 14000, 13000];
    long[4] hSpaceBefore = [18000, 14000, 12000, 11000];
    long[4] hSpaceAfter = [9000, 7000, 6000, 5000];

    /// x of the body rectangle.
    long bodyX() const pure nothrow @nogc @safe { return marginLeft; }
    /// y of the body rectangle.
    long bodyY() const pure nothrow @nogc @safe { return marginTop; }
    /// Width of the body rectangle.
    long bodyWidth() const pure nothrow @nogc @safe { return pageWidth - marginLeft - marginRight; }
    /// Height of the body rectangle.
    long bodyHeight() const pure nothrow @nogc @safe { return pageHeight - marginTop - marginBottom; }
    /// Bottom edge of the body rectangle.
    long bodyBottom() const pure nothrow @nogc @safe { return bodyY + bodyHeight; }

    /// The template of one header/footer slot: 0..2 are header left/center/right,
    /// 3..5 footer left/center/right; `even` selects the even-page variant.
    const(TextPart)[] slot(size_t index, bool even) const pure nothrow @nogc @safe
    {
        final switch (index)
        {
        case 0: return even ? headerLeftEven : headerLeft;
        case 1: return even ? headerCenterEven : headerCenter;
        case 2: return even ? headerRightEven : headerRight;
        case 3: return even ? footerLeftEven : footerLeft;
        case 4: return even ? footerCenterEven : footerCenter;
        case 5: return even ? footerRightEven : footerRight;
        }
    }
}

private enum Kind : ubyte
{
    length,
    integer,
    boolean,
    alignment,
    family,
    patterns,
    text,
}

private struct KeyDef
{
    string key;
    string field;
    Kind kind;
    long lo;
    long hi;
}

private enum keyDefs = [
    KeyDef("page-width", "pageWidth", Kind.length, 36000, long.max),
    KeyDef("page-height", "pageHeight", Kind.length, 36000, long.max),
    KeyDef("margin-top", "marginTop", Kind.length, 0, long.max),
    KeyDef("margin-bottom", "marginBottom", Kind.length, 0, long.max),
    KeyDef("margin-left", "marginLeft", Kind.length, 0, long.max),
    KeyDef("margin-right", "marginRight", Kind.length, 0, long.max),
    KeyDef("header-baseline", "headerBaseline", Kind.length, 0, long.max),
    KeyDef("footer-baseline", "footerBaseline", Kind.length, 0, long.max),
    KeyDef("page-start", "pageStart", Kind.integer, 1, 3000),
    KeyDef("body-font", "bodyFont", Kind.family, long.min, long.max),
    KeyDef("body-size", "bodySize", Kind.length, 1000, 200000),
    KeyDef("leading", "leading", Kind.length, 1000, long.max),
    KeyDef("line-skip", "lineSkip", Kind.length, 0, long.max),
    KeyDef("align", "textAlign", Kind.alignment, long.min, long.max),
    KeyDef("par-indent", "parIndent", Kind.length, 0, long.max),
    KeyDef("par-space", "parSpace", Kind.length, 0, long.max),
    KeyDef("tolerance", "tolerance", Kind.integer, 0, 10000),
    KeyDef("line-penalty", "linePenalty", Kind.integer, 0, 10000),
    KeyDef("hyphen-penalty", "hyphenPenalty", Kind.integer, -9999, 9999),
    KeyDef("ex-hyphen-penalty", "exHyphenPenalty", Kind.integer, -9999, 9999),
    KeyDef("adj-demerits", "adjDemerits", Kind.integer, 0, 1000000),
    KeyDef("double-hyphen-demerits", "doubleHyphenDemerits", Kind.integer, 0, 1000000),
    KeyDef("final-hyphen-demerits", "finalHyphenDemerits", Kind.integer, 0, 1000000),
    KeyDef("ragged-stretch", "raggedStretch", Kind.integer, 0, 100),
    KeyDef("hyphenate", "hyphenate", Kind.boolean, long.min, long.max),
    KeyDef("hyphen-patterns", "hyphenPatterns", Kind.patterns, long.min, long.max),
    KeyDef("heading-font", "headingFont", Kind.family, long.min, long.max),
    KeyDef("heading-bold", "headingBold", Kind.boolean, long.min, long.max),
    KeyDef("heading-italic", "headingItalic", Kind.boolean, long.min, long.max),
    KeyDef("heading-align", "headingAlign", Kind.alignment, long.min, long.max),
    KeyDef("heading-number", "headingNumber", Kind.boolean, long.min, long.max),
    KeyDef("heading-number-gap", "headingNumberGap", Kind.length, 0, long.max),
    KeyDef("h1-newpage", "h1Newpage", Kind.boolean, long.min, long.max),
    KeyDef("h1-size", "hSize[0]", Kind.length, 1000, 200000),
    KeyDef("h2-size", "hSize[1]", Kind.length, 1000, 200000),
    KeyDef("h3-size", "hSize[2]", Kind.length, 1000, 200000),
    KeyDef("h4-size", "hSize[3]", Kind.length, 1000, 200000),
    KeyDef("h1-leading", "hLeading[0]", Kind.length, 1000, long.max),
    KeyDef("h2-leading", "hLeading[1]", Kind.length, 1000, long.max),
    KeyDef("h3-leading", "hLeading[2]", Kind.length, 1000, long.max),
    KeyDef("h4-leading", "hLeading[3]", Kind.length, 1000, long.max),
    KeyDef("h1-space-before", "hSpaceBefore[0]", Kind.length, 0, long.max),
    KeyDef("h2-space-before", "hSpaceBefore[1]", Kind.length, 0, long.max),
    KeyDef("h3-space-before", "hSpaceBefore[2]", Kind.length, 0, long.max),
    KeyDef("h4-space-before", "hSpaceBefore[3]", Kind.length, 0, long.max),
    KeyDef("h1-space-after", "hSpaceAfter[0]", Kind.length, 0, long.max),
    KeyDef("h2-space-after", "hSpaceAfter[1]", Kind.length, 0, long.max),
    KeyDef("h3-space-after", "hSpaceAfter[2]", Kind.length, 0, long.max),
    KeyDef("h4-space-after", "hSpaceAfter[3]", Kind.length, 0, long.max),
    KeyDef("list-indent", "listIndent", Kind.length, 0, long.max),
    KeyDef("list-marker-gap", "listMarkerGap", Kind.length, 0, long.max),
    KeyDef("list-space", "listSpace", Kind.length, 0, long.max),
    KeyDef("list-item-space", "listItemSpace", Kind.length, 0, long.max),
    KeyDef("quote-indent", "quoteIndent", Kind.length, 0, long.max),
    KeyDef("quote-space", "quoteSpace", Kind.length, 0, long.max),
    KeyDef("pre-font", "preFont", Kind.family, long.min, long.max),
    KeyDef("pre-size", "preSize", Kind.length, 1000, 200000),
    KeyDef("pre-leading", "preLeading", Kind.length, 1000, long.max),
    KeyDef("pre-indent", "preIndent", Kind.length, 0, long.max),
    KeyDef("pre-space", "preSpace", Kind.length, 0, long.max),
    KeyDef("table-col-gap", "tableColGap", Kind.length, 0, long.max),
    KeyDef("table-row-space", "tableRowSpace", Kind.length, 0, long.max),
    KeyDef("table-rule-space", "tableRuleSpace", Kind.length, 0, long.max),
    KeyDef("table-rule-thickness", "tableRuleThickness", Kind.length, 1, long.max),
    KeyDef("table-space", "tableSpace", Kind.length, 0, long.max),
    KeyDef("table-leading", "tableLeading", Kind.length, 1000, long.max),
    KeyDef("rule-thickness", "ruleThickness", Kind.length, 1, long.max),
    KeyDef("rule-space", "ruleSpace", Kind.length, 0, long.max),
    KeyDef("footnote-font", "footnoteFont", Kind.family, long.min, long.max),
    KeyDef("footnote-size", "footnoteSize", Kind.length, 1000, 200000),
    KeyDef("footnote-leading", "footnoteLeading", Kind.length, 1000, long.max),
    KeyDef("footnote-indent", "footnoteIndent", Kind.length, 0, long.max),
    KeyDef("footnote-mark-gap", "footnoteMarkGap", Kind.length, 0, long.max),
    KeyDef("footnote-mark-size", "footnoteMarkSize", Kind.length, 1000, 200000),
    KeyDef("footnote-mark-raise", "footnoteMarkRaise", Kind.length, 0, long.max),
    KeyDef("footnote-item-space", "footnoteItemSpace", Kind.length, 0, long.max),
    KeyDef("footnote-rule-width", "footnoteRuleWidth", Kind.length, 0, long.max),
    KeyDef("footnote-rule-thickness", "footnoteRuleThickness", Kind.length, 1, long.max),
    KeyDef("footnote-space-before", "footnoteSpaceBefore", Kind.length, 0, long.max),
    KeyDef("footnote-space-after", "footnoteSpaceAfter", Kind.length, 0, long.max),
    KeyDef("footnote-min-split", "footnoteMinSplit", Kind.integer, 1, 100),
    KeyDef("footnote-max-height", "footnoteMaxHeight", Kind.length, 1000, long.max),
    KeyDef("mark-size", "markSize", Kind.length, 1000, 200000),
    KeyDef("mark-raise", "markRaise", Kind.length, 0, long.max),
    KeyDef("figure-width", "figureWidth", Kind.length, 0, long.max),
    KeyDef("figure-frame", "figureFrame", Kind.boolean, long.min, long.max),
    KeyDef("figure-caption-font", "figureCaptionFont", Kind.family, long.min, long.max),
    KeyDef("figure-caption-size", "figureCaptionSize", Kind.length, 1000, 200000),
    KeyDef("figure-caption-leading", "figureCaptionLeading", Kind.length, 1000, long.max),
    KeyDef("figure-caption-align", "figureCaptionAlign", Kind.alignment, long.min, long.max),
    KeyDef("figure-caption-space", "figureCaptionSpace", Kind.length, 0, long.max),
    KeyDef("figure-caption-prefix", "figureCaptionPrefix", Kind.text, long.min, long.max),
    KeyDef("figure-caption-gap", "figureCaptionGap", Kind.length, 0, long.max),
    KeyDef("float-space-after", "floatSpaceAfter", Kind.length, 0, long.max),
    KeyDef("float-min-body", "floatMinBody", Kind.length, 0, long.max),
    KeyDef("widows", "widows", Kind.integer, 1, 20),
    KeyDef("orphans", "orphans", Kind.integer, 1, 20),
    KeyDef("keep-with-next", "keepWithNext", Kind.boolean, long.min, long.max),
    KeyDef("toc-depth", "tocDepth", Kind.integer, 0, 4),
    KeyDef("toc-font", "tocFont", Kind.family, long.min, long.max),
    KeyDef("toc-size", "tocSize", Kind.length, 1000, 200000),
    KeyDef("toc-leading", "tocLeading", Kind.length, 1000, long.max),
    KeyDef("toc-indent", "tocIndent", Kind.length, 0, long.max),
    KeyDef("toc-number-gap", "tocNumberGap", Kind.length, 0, long.max),
    KeyDef("toc-reserve", "tocReserve", Kind.length, 0, long.max),
    KeyDef("toc-leader", "tocLeader", Kind.text, long.min, long.max),
    KeyDef("toc-leader-gap", "tocLeaderGap", Kind.length, 0, long.max),
    KeyDef("toc-entry-space", "tocEntrySpace", Kind.length, 0, long.max),
    KeyDef("toc-title", "tocTitle", Kind.text, long.min, long.max),
    KeyDef("toc-title-font", "tocTitleFont", Kind.family, long.min, long.max),
    KeyDef("toc-title-size", "tocTitleSize", Kind.length, 1000, 200000),
    KeyDef("toc-title-space-after", "tocTitleSpaceAfter", Kind.length, 0, long.max),
    KeyDef("header-font", "headerFont", Kind.family, long.min, long.max),
    KeyDef("header-size", "headerSize", Kind.length, 1000, 200000),
    KeyDef("header-left", "headerLeft", Kind.text, long.min, long.max),
    KeyDef("header-center", "headerCenter", Kind.text, long.min, long.max),
    KeyDef("header-right", "headerRight", Kind.text, long.min, long.max),
    KeyDef("footer-left", "footerLeft", Kind.text, long.min, long.max),
    KeyDef("footer-center", "footerCenter", Kind.text, long.min, long.max),
    KeyDef("footer-right", "footerRight", Kind.text, long.min, long.max),
    KeyDef("header-left-even", "headerLeftEven", Kind.text, long.min, long.max),
    KeyDef("header-center-even", "headerCenterEven", Kind.text, long.min, long.max),
    KeyDef("header-right-even", "headerRightEven", Kind.text, long.min, long.max),
    KeyDef("footer-left-even", "footerLeftEven", Kind.text, long.min, long.max),
    KeyDef("footer-center-even", "footerCenterEven", Kind.text, long.min, long.max),
    KeyDef("footer-right-even", "footerRightEven", Kind.text, long.min, long.max)
];

private enum keyIndex = () {
    size_t[string] m;
    foreach (i, d; keyDefs)
        m[d.key] = i;
    return m;
}();

/// Names of all settings keys, in table order.
string[] settingKeys() pure nothrow @safe
{
    string[] r;
    foreach (d; keyDefs)
        r ~= d.key;
    return r;
}

private void assignNumber(ref Settings s, size_t idx, long v) pure nothrow @safe
{
    sw: switch (idx)
    {
        static foreach (i, d; keyDefs)
            static if (d.kind == Kind.length || d.kind == Kind.integer)
            {
            case i:
                mixin("s." ~ d.field ~ " = v;");
                break sw;
            }
    default:
        assert(0);
    }
}

private void assignBool(ref Settings s, size_t idx, bool v) pure nothrow @safe
{
    sw: switch (idx)
    {
        static foreach (i, d; keyDefs)
            static if (d.kind == Kind.boolean)
            {
            case i:
                mixin("s." ~ d.field ~ " = v;");
                break sw;
            }
    default:
        assert(0);
    }
}

private void assignAlign(ref Settings s, size_t idx, Align v) pure nothrow @safe
{
    sw: switch (idx)
    {
        static foreach (i, d; keyDefs)
            static if (d.kind == Kind.alignment)
            {
            case i:
                mixin("s." ~ d.field ~ " = v;");
                break sw;
            }
    default:
        assert(0);
    }
}

private void assignFamily(ref Settings s, size_t idx, Family v) pure nothrow @safe
{
    sw: switch (idx)
    {
        static foreach (i, d; keyDefs)
            static if (d.kind == Kind.family)
            {
            case i:
                mixin("s." ~ d.field ~ " = v;");
                break sw;
            }
    default:
        assert(0);
    }
}

private void assignPatterns(ref Settings s, size_t idx, PatternsId v) pure nothrow @safe
{
    sw: switch (idx)
    {
        static foreach (i, d; keyDefs)
            static if (d.kind == Kind.patterns)
            {
            case i:
                mixin("s." ~ d.field ~ " = v;");
                break sw;
            }
    default:
        assert(0);
    }
}

private void assignText(ref Settings s, size_t idx, Template v) pure nothrow @safe
{
    sw: switch (idx)
    {
        static foreach (i, d; keyDefs)
            static if (d.kind == Kind.text)
            {
            case i:
                mixin("s." ~ d.field ~ " = v;");
                break sw;
            }
    default:
        assert(0);
    }
}

/// Settings with every default in force (no `settings.cfg`).
Settings defaultSettings() pure @safe
{
    Settings s;
    s.figureCaptionPrefix = [TextPart(false, Placeholder.page, "Figure")];
    s.tocLeader = [TextPart(false, Placeholder.page, ".")];
    s.tocTitle = [TextPart(false, Placeholder.page, "Contents")];
    bool[keyDefs.length] none;
    finalizeDefaults(s, none[]);
    return s;
}

private void finalizeDefaults(ref Settings s, const(bool)[] assigned) pure @safe
{
    if (!assigned[keyIndex["footer-baseline"]])
        s.footerBaseline = s.pageHeight - 36000;
    if (!assigned[keyIndex["footnote-max-height"]])
        s.footnoteMaxHeight = fdiv(s.bodyHeight, 2);
    static foreach (n; ["header-left", "header-center", "header-right", "footer-left", "footer-center", "footer-right"])
    {
        if (!assigned[keyIndex[n ~ "-even"]])
            assignText(s, keyIndex[n ~ "-even"], s.slot(slotOf(n), false).dup);
    }
}

private size_t slotOf(string name) pure nothrow @nogc @safe
{
    switch (name)
    {
    case "header-left": return 0;
    case "header-center": return 1;
    case "header-right": return 2;
    case "footer-left": return 3;
    case "footer-center": return 4;
    default: return 5;
    }
}

private bool parseFamily(const(char)[] v, out Family f) pure nothrow @nogc @safe
{
    switch (v)
    {
    case "serif": f = Family.serif; return true;
    case "sans": f = Family.sans; return true;
    case "mono": f = Family.mono; return true;
    default: return false;
    }
}

/// Parses an alignment word (`justify`, `left`, `right`, `center`).
bool parseAlign(const(char)[] v, out Align a) pure nothrow @nogc @safe
{
    switch (v)
    {
    case "justify": a = Align.justify; return true;
    case "left": a = Align.left; return true;
    case "right": a = Align.right; return true;
    case "center": a = Align.center; return true;
    default: return false;
    }
}

/// Parses a font family word.
bool parseFamilyWord(const(char)[] v, out Family f) pure nothrow @nogc @safe
{
    return parseFamily(v, f);
}

private Placeholder placeholderByName(const(char)[] n, out bool ok) pure nothrow @nogc @safe
{
    ok = true;
    switch (n)
    {
    case "page": return Placeholder.page;
    case "pages": return Placeholder.pages;
    case "title": return Placeholder.title;
    case "author": return Placeholder.author;
    case "date": return Placeholder.date;
    case "chapter": return Placeholder.chapter;
    case "section": return Placeholder.section;
    default:
        ok = false;
        return Placeholder.page;
    }
}

/// Parses a `text` value. `lineNo` is used for error positions; `valueOff` is the
/// byte offset of the value inside `line`.
private Template parseTextValue(const(char)[] line, size_t valueOff, size_t valueEnd, int lineNo)
{
    enum f = "settings.cfg";
    Template parts;
    char[] lit;
    void flush()
    {
        if (lit.length)
        {
            parts ~= TextPart(false, Placeholder.page, lit.idup);
            lit.length = 0;
        }
    }

    size_t i = valueOff;
    while (i < valueEnd)
    {
        immutable c = line[i];
        if (c == '\\')
        {
            if (i + 1 < valueEnd && (line[i + 1] == '{' || line[i + 1] == '}' || line[i + 1] == '\\'))
            {
                lit ~= line[i + 1];
                i += 2;
            }
            else
                fail(f, lineNo, columnAt(line, i), ErrorCode.badEscape);
        }
        else if (c == '{')
        {
            size_t j = i + 1;
            while (j < valueEnd && line[j] != '}')
                ++j;
            if (j >= valueEnd)
                fail(f, lineNo, columnAt(line, i), ErrorCode.unknownPlaceholder);
            bool ok;
            auto ph = placeholderByName(line[i + 1 .. j], ok);
            if (!ok)
                fail(f, lineNo, columnAt(line, i), ErrorCode.unknownPlaceholder);
            flush();
            parts ~= TextPart(true, ph, "");
            i = j + 1;
        }
        else if (c == '}')
            fail(f, lineNo, columnAt(line, i), ErrorCode.strayBrace);
        else
        {
            lit ~= c;
            ++i;
        }
    }
    flush();
    return parts;
}

private bool hasPlaceholder(const Template t) pure nothrow @nogc @safe
{
    foreach (p; t)
        if (p.isPlaceholder)
            return true;
    return false;
}

/// Parses and validates the text of a `settings.cfg` file.
/// Throws `TypesetError` with the first error found.
Settings parseSettings(const(char)[] text)
{
    enum file = "settings.cfg";
    Settings s;
    s.figureCaptionPrefix = [TextPart(false, Placeholder.page, "Figure")];
    s.tocLeader = [TextPart(false, Placeholder.page, ".")];
    s.tocTitle = [TextPart(false, Placeholder.page, "Contents")];
    bool[keyDefs.length] assigned;

    // The six keys of the body-rectangle check, and where each was last assigned.
    int rectLine = 0, rectCol = 0;
    static immutable string[6] rectKeys = ["page-width", "page-height", "margin-top",
        "margin-bottom", "margin-left", "margin-right"];

    int lineNo = 0;
    foreach (line; splitLines(text))
    {
        ++lineNo;
        size_t i;
        while (i < line.length && (line[i] == ' ' || line[i] == '\t'))
            ++i;
        if (i >= line.length || line[i] == '#')
            continue;
        immutable a = parseAssignment(line, true);
        if (!a.ok)
            fail(file, lineNo, columnAt(line, a.keyStart), ErrorCode.badSyntax);
        immutable keyCol = columnAt(line, a.keyStart);
        auto ip = a.key(line) in keyIndex;
        if (ip is null)
            fail(file, lineNo, keyCol, ErrorCode.unknownSetting);
        immutable idx = *ip;
        if (assigned[idx])
            fail(file, lineNo, keyCol, ErrorCode.duplicateSetting);

        // Position of the value: first non-blank after "=", or one past the line.
        size_t vpos = a.keyEnd;
        while (vpos < line.length && line[vpos] != '=')
            ++vpos;
        ++vpos;
        while (vpos < line.length && (line[vpos] == ' ' || line[vpos] == '\t'))
            ++vpos;
        immutable valCol = vpos >= line.length ? columnAt(line, line.length) : columnAt(line, vpos);
        const(char)[] value = a.value(line);
        immutable def = keyDefs[idx];

        void bad(ErrorCode c)
        {
            fail(file, lineNo, valCol, c);
        }

        final switch (def.kind)
        {
        case Kind.length:
        case Kind.integer:
            long v;
            if (def.kind == Kind.length ? !parseLength(value, v) : !parseInteger(value, v))
                bad(def.kind == Kind.length ? ErrorCode.badLength : ErrorCode.badInteger);
            if (v < def.lo || v > def.hi)
                bad(ErrorCode.badValue);
            assignNumber(s, idx, v);
            break;
        case Kind.boolean:
            if (value == "on")
                assignBool(s, idx, true);
            else if (value == "off")
                assignBool(s, idx, false);
            else
                bad(ErrorCode.badBoolean);
            break;
        case Kind.alignment:
            Align al;
            if (!parseAlign(value, al))
                bad(ErrorCode.badEnum);
            assignAlign(s, idx, al);
            break;
        case Kind.family:
            Family fam;
            if (!parseFamily(value, fam))
                bad(ErrorCode.unknownFont);
            assignFamily(s, idx, fam);
            break;
        case Kind.patterns:
            if (value == "english")
                assignPatterns(s, idx, PatternsId.english);
            else if (value == "minimal")
                assignPatterns(s, idx, PatternsId.minimal);
            else
                bad(ErrorCode.unknownPatterns);
            break;
        case Kind.text:
            auto t = parseTextValue(line, a.valueStart, a.valueEnd, lineNo);
            switch (def.key)
            {
            case "figure-caption-prefix":
            case "toc-title":
                if (hasPlaceholder(t))
                    bad(ErrorCode.badValue);
                break;
            case "toc-leader":
                if (hasPlaceholder(t))
                    bad(ErrorCode.badValue);
                immutable lit = literalText(t);
                immutable n = codepointCount(lit);
                if (n < 1 || n > 8)
                    bad(ErrorCode.badValue);
                foreach (ch; lit)
                    if (ch == ' ')
                        bad(ErrorCode.badValue);
                break;
            default:
                break;
            }
            assignText(s, idx, t);
            break;
        }
        assigned[idx] = true;
        foreach (rk; rectKeys)
            if (def.key == rk)
            {
                rectLine = lineNo;
                rectCol = valCol;
            }
    }
    if (s.bodyWidth < 36000 || s.bodyHeight < 36000)
        fail(file, rectLine, rectCol, ErrorCode.badValue);
    finalizeDefaults(s, assigned[]);
    return s;
}

private size_t codepointCount(const(char)[] s) pure nothrow @nogc @safe
{
    import typeset.arith : cc = codepointCount;

    return cc(s);
}
