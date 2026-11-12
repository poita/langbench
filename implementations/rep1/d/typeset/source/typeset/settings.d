/**
 * The `settings.cfg` file: the 126 layout settings, their defaults, value
 * parsers and range checks.
 *
 * Each setting is a field of $(LREF Settings) annotated with a UDA that
 * names its key and says how its value is parsed ($(LREF Len), $(LREF Int),
 * $(LREF Flag), $(LREF Choice) or $(LREF Txt)). $(LREF parseSettings)
 * discovers the fields at compile time.
 */
module typeset.settings;

import std.conv : to;
import std.traits : FieldNameTuple, getUDAs, hasUDA, EnumMembers;

import typeset.errors;
import typeset.hyphenation : PatternId;
import typeset.metrics : Family;

/// Text alignment of a horizontal list.
enum Align : ubyte
{
    justify,
    left,
    right,
    center
}

/// Placeholders usable in header/footer text.
enum Placeholder : ubyte
{
    page,
    pages,
    title,
    author,
    date,
    chapter,
    section
}

/// One piece of a text setting: literal text or a placeholder.
struct TextPart
{
    bool isPlaceholder;
    Placeholder placeholder;
    dstring literal;
}

/// A parsed text setting.
alias Template = TextPart[];

// ---- UDAs --------------------------------------------------------------

/// A length setting with an inclusive range in millipoints.
struct Len
{
    string key;
    long lo = 0;
    long hi = long.max;
}

/// An integer setting with an inclusive range.
struct Int
{
    string key;
    long lo;
    long hi;
}

/// An `on`/`off` setting.
struct Flag
{
    string key;
}

/// An enumerated setting; `code` is the error for a value outside the enum.
struct Choice
{
    string key;
    string code;
}

/// A text setting. `plain` text may not contain placeholders; when `maxLen`
/// is non-zero the text must have `1 .. maxLen` characters, none a space.
struct Txt
{
    string key;
    bool plain = false;
    size_t maxLen = 0;
}

/// All layout settings with their defaults.
struct Settings
{
    // ---- page geometry
    @Len("page-width", 36_000) long pageWidth = 612_000;
    @Len("page-height", 36_000) long pageHeight = 792_000;
    @Len("margin-top") long marginTop = 72_000;
    @Len("margin-bottom") long marginBottom = 72_000;
    @Len("margin-left") long marginLeft = 72_000;
    @Len("margin-right") long marginRight = 72_000;
    @Len("header-baseline") long headerBaseline = 36_000;
    @Len("footer-baseline") long footerBaseline = 756_000; // derived: page-height - 36pt
    @Int("page-start", 1, 3000) long pageStart = 1;

    // ---- body text
    @Choice("body-font", "unknown-font") Family bodyFont = Family.serif;
    @Len("body-size", 1000, 200_000) long bodySize = 10_000;
    @Len("leading", 1000) long leading = 12_000;
    @Len("line-skip") long lineSkip = 1000;
    @Choice("align", "bad-enum") Align align_ = Align.justify;
    @Len("par-indent") long parIndent = 18_000;
    @Len("par-space") long parSpace = 0;

    // ---- line breaking
    @Int("tolerance", 0, 10_000) long tolerance = 1000;
    @Int("line-penalty", 0, 10_000) long linePenalty = 10;
    @Int("hyphen-penalty", -9999, 9999) long hyphenPenalty = 50;
    @Int("ex-hyphen-penalty", -9999, 9999) long exHyphenPenalty = 50;
    @Int("adj-demerits", 0, 1_000_000) long adjDemerits = 10_000;
    @Int("double-hyphen-demerits", 0, 1_000_000) long doubleHyphenDemerits = 10_000;
    @Int("final-hyphen-demerits", 0, 1_000_000) long finalHyphenDemerits = 5000;
    @Int("ragged-stretch", 0, 100) long raggedStretch = 3;
    @Flag("hyphenate") bool hyphenate = true;
    @Choice("hyphen-patterns", "unknown-patterns") PatternId hyphenPatterns = PatternId.english;

    // ---- headings
    @Choice("heading-font", "unknown-font") Family headingFont = Family.sans;
    @Flag("heading-bold") bool headingBold = true;
    @Flag("heading-italic") bool headingItalic = false;
    @Choice("heading-align", "bad-enum") Align headingAlign = Align.left;
    @Flag("heading-number") bool headingNumber = true;
    @Len("heading-number-gap") long headingNumberGap = 6000;
    @Flag("h1-newpage") bool h1Newpage = false;
    @Len("h1-size", 1000, 200_000) long h1Size = 20_000;
    @Len("h2-size", 1000, 200_000) long h2Size = 14_000;
    @Len("h3-size", 1000, 200_000) long h3Size = 12_000;
    @Len("h4-size", 1000, 200_000) long h4Size = 11_000;
    @Len("h1-leading", 1000) long h1Leading = 24_000;
    @Len("h2-leading", 1000) long h2Leading = 17_000;
    @Len("h3-leading", 1000) long h3Leading = 14_000;
    @Len("h4-leading", 1000) long h4Leading = 13_000;
    @Len("h1-space-before") long h1SpaceBefore = 18_000;
    @Len("h2-space-before") long h2SpaceBefore = 14_000;
    @Len("h3-space-before") long h3SpaceBefore = 12_000;
    @Len("h4-space-before") long h4SpaceBefore = 11_000;
    @Len("h1-space-after") long h1SpaceAfter = 9000;
    @Len("h2-space-after") long h2SpaceAfter = 7000;
    @Len("h3-space-after") long h3SpaceAfter = 6000;
    @Len("h4-space-after") long h4SpaceAfter = 5000;

    // ---- lists, quotes, preformatted text
    @Len("list-indent") long listIndent = 18_000;
    @Len("list-marker-gap") long listMarkerGap = 4000;
    @Len("list-space") long listSpace = 6000;
    @Len("list-item-space") long listItemSpace = 0;
    @Len("quote-indent") long quoteIndent = 18_000;
    @Len("quote-space") long quoteSpace = 6000;
    @Choice("pre-font", "unknown-font") Family preFont = Family.mono;
    @Len("pre-size", 1000, 200_000) long preSize = 9000;
    @Len("pre-leading", 1000) long preLeading = 11_000;
    @Len("pre-indent") long preIndent = 0;
    @Len("pre-space") long preSpace = 6000;

    // ---- tables and rules
    @Len("table-col-gap") long tableColGap = 8000;
    @Len("table-row-space") long tableRowSpace = 2000;
    @Len("table-rule-space") long tableRuleSpace = 2000;
    @Len("table-rule-thickness", 1) long tableRuleThickness = 400;
    @Len("table-space") long tableSpace = 6000;
    @Len("table-leading", 1000) long tableLeading = 12_000;
    @Len("rule-thickness", 1) long ruleThickness = 500;
    @Len("rule-space") long ruleSpace = 6000;

    // ---- footnotes
    @Choice("footnote-font", "unknown-font") Family footnoteFont = Family.serif;
    @Len("footnote-size", 1000, 200_000) long footnoteSize = 8000;
    @Len("footnote-leading", 1000) long footnoteLeading = 10_000;
    @Len("footnote-indent") long footnoteIndent = 10_000;
    @Len("footnote-mark-gap") long footnoteMarkGap = 2000;
    @Len("footnote-mark-size", 1000, 200_000) long footnoteMarkSize = 6000;
    @Len("footnote-mark-raise") long footnoteMarkRaise = 2000;
    @Len("footnote-item-space") long footnoteItemSpace = 2000;
    @Len("footnote-rule-width") long footnoteRuleWidth = 120_000;
    @Len("footnote-rule-thickness", 1) long footnoteRuleThickness = 400;
    @Len("footnote-space-before") long footnoteSpaceBefore = 6000;
    @Len("footnote-space-after") long footnoteSpaceAfter = 3000;
    @Int("footnote-min-split", 1, 100) long footnoteMinSplit = 1;
    @Len("footnote-max-height", 1000) long footnoteMaxHeight = 0; // derived: body-height div 2
    @Len("mark-size", 1000, 200_000) long markSize = 7000;
    @Len("mark-raise") long markRaise = 3000;

    // ---- figures
    @Len("figure-width") long figureWidth = 0;
    @Flag("figure-frame") bool figureFrame = true;
    @Choice("figure-caption-font", "unknown-font") Family figureCaptionFont = Family.serif;
    @Len("figure-caption-size", 1000, 200_000) long figureCaptionSize = 9000;
    @Len("figure-caption-leading", 1000) long figureCaptionLeading = 11_000;
    @Choice("figure-caption-align", "bad-enum") Align figureCaptionAlign = Align.center;
    @Len("figure-caption-space") long figureCaptionSpace = 4000;
    @Txt("figure-caption-prefix", true) dstring figureCaptionPrefix = "Figure"d;
    @Len("figure-caption-gap") long figureCaptionGap = 4000;
    @Len("float-space-after") long floatSpaceAfter = 12_000;
    @Len("float-min-body") long floatMinBody = 24_000;

    // ---- page breaking
    @Int("widows", 1, 20) long widows = 2;
    @Int("orphans", 1, 20) long orphans = 2;
    @Flag("keep-with-next") bool keepWithNext = true;

    // ---- table of contents
    @Int("toc-depth", 0, 4) long tocDepth = 2;
    @Choice("toc-font", "unknown-font") Family tocFont = Family.serif;
    @Len("toc-size", 1000, 200_000) long tocSize = 10_000;
    @Len("toc-leading", 1000) long tocLeading = 14_000;
    @Len("toc-indent") long tocIndent = 18_000;
    @Len("toc-number-gap") long tocNumberGap = 6000;
    @Len("toc-reserve") long tocReserve = 30_000;
    @Txt("toc-leader", true, 8) dstring tocLeader = "."d;
    @Len("toc-leader-gap") long tocLeaderGap = 3000;
    @Len("toc-entry-space") long tocEntrySpace = 0;
    @Txt("toc-title", true) dstring tocTitle = "Contents"d;
    @Choice("toc-title-font", "unknown-font") Family tocTitleFont = Family.sans;
    @Len("toc-title-size", 1000, 200_000) long tocTitleSize = 20_000;
    @Len("toc-title-space-after") long tocTitleSpaceAfter = 12_000;

    // ---- running headers and footers
    @Choice("header-font", "unknown-font") Family headerFont = Family.sans;
    @Len("header-size", 1000, 200_000) long headerSize = 9000;
    @Txt("header-left") Template headerLeft;
    @Txt("header-center") Template headerCenter;
    @Txt("header-right") Template headerRight;
    @Txt("footer-left") Template footerLeft;
    @Txt("footer-center") Template footerCenter;
    @Txt("footer-right") Template footerRight;
    @Txt("header-left-even") Template headerLeftEven;
    @Txt("header-center-even") Template headerCenterEven;
    @Txt("header-right-even") Template headerRightEven;
    @Txt("footer-left-even") Template footerLeftEven;
    @Txt("footer-center-even") Template footerCenterEven;
    @Txt("footer-right-even") Template footerRightEven;

    // ---- derived geometry
    /// Left edge of the body rectangle.
    long bodyX() const pure nothrow @safe @nogc { return marginLeft; }
    /// Top edge of the body rectangle.
    long bodyY() const pure nothrow @safe @nogc { return marginTop; }
    /// Width of the body rectangle.
    long bodyWidth() const pure nothrow @safe @nogc { return pageWidth - marginLeft - marginRight; }
    /// Height of the body rectangle.
    long bodyHeight() const pure nothrow @safe @nogc { return pageHeight - marginTop - marginBottom; }
    /// Bottom edge of the body rectangle.
    long bodyBottom() const pure nothrow @safe @nogc { return bodyY + bodyHeight; }

    /// Size, leading, space-before and space-after of heading level 1..4.
    long headingSize(int level) const pure nothrow @safe @nogc
    {
        final switch (level)
        {
        case 1: return h1Size;
        case 2: return h2Size;
        case 3: return h3Size;
        case 4: return h4Size;
        }
    }
    /// ditto
    long headingLeading(int level) const pure nothrow @safe @nogc
    {
        final switch (level)
        {
        case 1: return h1Leading;
        case 2: return h2Leading;
        case 3: return h3Leading;
        case 4: return h4Leading;
        }
    }
    /// ditto
    long headingSpaceBefore(int level) const pure nothrow @safe @nogc
    {
        final switch (level)
        {
        case 1: return h1SpaceBefore;
        case 2: return h2SpaceBefore;
        case 3: return h3SpaceBefore;
        case 4: return h4SpaceBefore;
        }
    }
    /// ditto
    long headingSpaceAfter(int level) const pure nothrow @safe @nogc
    {
        final switch (level)
        {
        case 1: return h1SpaceAfter;
        case 2: return h2SpaceAfter;
        case 3: return h3SpaceAfter;
        case 4: return h4SpaceAfter;
        }
    }
}

// ---- value parsers -----------------------------------------------------

private bool isDigit(dchar c) pure nothrow @safe @nogc
{
    return c >= '0' && c <= '9';
}

/// Parses a length literal (see the specification) into millipoints.
bool parseLength(const(dchar)[] v, out long result) pure nothrow @safe @nogc
{
    size_t i = 0;
    bool neg = false;
    if (i < v.length && v[i] == '-')
    {
        neg = true;
        ++i;
    }
    size_t st = i;
    long whole = 0;
    while (i < v.length && isDigit(v[i]))
    {
        whole = whole * 10 + (v[i] - '0');
        if (i - st > 14)
            return false;
        ++i;
    }
    if (i == st)
        return false;
    long frac = 0, scale10 = 1;
    if (i < v.length && v[i] == '.')
    {
        ++i;
        st = i;
        while (i < v.length && isDigit(v[i]))
        {
            frac = frac * 10 + (v[i] - '0');
            scale10 *= 10;
            ++i;
        }
        immutable k = i - st;
        if (k < 1 || k > 3)
            return false;
    }
    long unit;
    const rest = v[i .. $];
    if (rest.length == 0)
        unit = 1;
    else if (rest == "pt"d)
        unit = 1000;
    else if (rest == "mm"d)
        unit = 2835;
    else if (rest == "cm"d)
        unit = 28_350;
    else if (rest == "in"d)
        unit = 72_000;
    else if (rest == "pc"d)
        unit = 12_000;
    else
        return false;
    long r = ((whole * scale10 + frac) * unit) / scale10; // non-negative: floor == truncation
    result = neg ? -r : r;
    return true;
}

///
@safe pure nothrow @nogc unittest
{
    long r;
    assert(parseLength("2.5pt"d, r) && r == 2500);
    assert(parseLength("0.5pt"d, r) && r == 500);
    assert(parseLength("1.5mm"d, r) && r == 4252);
    assert(parseLength("-6pt"d, r) && r == -6000);
    assert(parseLength("734"d, r) && r == 734);
    assert(!parseLength("20px"d, r));
    assert(!parseLength(""d, r));
    assert(!parseLength("+1"d, r));
    assert(!parseLength("1.2345pt"d, r));
    assert(!parseLength(".5pt"d, r));
    assert(!parseLength("5.pt"d, r));
}

/// Parses an integer literal `[-]?DIGITS`.
bool parseInteger(const(dchar)[] v, out long result) pure nothrow @safe @nogc
{
    size_t i = 0;
    bool neg = false;
    if (i < v.length && v[i] == '-')
    {
        neg = true;
        ++i;
    }
    if (i == v.length || v.length - i > 17)
        return false;
    long r = 0;
    for (; i < v.length; ++i)
    {
        if (!isDigit(v[i]))
            return false;
        r = r * 10 + (v[i] - '0');
    }
    result = neg ? -r : r;
    return true;
}

/// Parses a text setting. Throws `TypesetError` positioned relative to
/// `col0` (the column of the value's first character) on `line`.
Template parseText(const(dchar)[] v, string file, int line, int col0) pure @safe
{
    Template parts;
    dchar[] lit;
    void flush()
    {
        if (lit.length)
        {
            parts ~= TextPart(false, Placeholder.page, lit.idup);
            lit = null;
        }
    }

    size_t i = 0;
    while (i < v.length)
    {
        immutable c = v[i];
        if (c == '\\')
        {
            if (i + 1 < v.length && (v[i + 1] == '{' || v[i + 1] == '}' || v[i + 1] == '\\'))
            {
                lit ~= v[i + 1];
                i += 2;
            }
            else
                fail(file, line, col0 + cast(int) i, "bad-escape");
        }
        else if (c == '{')
        {
            size_t j = i + 1;
            while (j < v.length && v[j] != '}')
                ++j;
            if (j >= v.length)
                fail(file, line, col0 + cast(int) i, "unknown-placeholder");
            const name = v[i + 1 .. j];
            Placeholder ph;
            bool found = false;
            foreach (m; EnumMembers!Placeholder)
            {
                if (name == m.to!string.to!dstring)
                {
                    ph = m;
                    found = true;
                }
            }
            if (!found)
                fail(file, line, col0 + cast(int) i, "unknown-placeholder");
            flush();
            parts ~= TextPart(true, ph, null);
            i = j + 1;
        }
        else if (c == '}')
            fail(file, line, col0 + cast(int) i, "stray-brace");
        else
        {
            lit ~= c;
            ++i;
        }
    }
    flush();
    return parts;
}

@safe pure unittest
{
    auto t = parseText("a {page} b\\{"d, "settings.cfg", 1, 1);
    assert(t.length == 3 && t[1].isPlaceholder && t[1].placeholder == Placeholder.page);
    assert(t[2].literal == " b{"d);
}

// ---- the settings file -------------------------------------------------

private immutable string[] allKeys = () {
    string[] keys;
    static foreach (name; FieldNameTuple!Settings)
    {
        static foreach (uda; __traits(getAttributes, __traits(getMember, Settings, name)))
            keys ~= uda.key;
    }
    return keys;
}();

/// Parses and validates a settings file. A null/empty source gives the defaults.
/// Throws `TypesetError` on the first error.
Settings parseSettings(string source)
{
    enum file = "settings.cfg";
    Settings s;
    bool[string] assigned;
    int geoLine = 0, geoCol = 0;

    // Split into lines (a trailing LF does not start a new line).
    string[] rawLines;
    {
        size_t start = 0;
        foreach (i, c; source)
        {
            if (c == '\n')
            {
                rawLines ~= source[start .. i];
                start = i + 1;
            }
        }
        if (start < source.length)
            rawLines ~= source[start .. $];
    }

    foreach (lineIdx, raw; rawLines)
    {
        immutable int ln = cast(int) lineIdx + 1;
        const dstring line = raw.to!dstring;
        size_t p = 0;
        while (p < line.length && (line[p] == ' ' || line[p] == '\t'))
            ++p;
        if (p == line.length || line[p] == '#')
            continue;
        immutable size_t keyStart = p;
        while (p < line.length && ((line[p] >= 'a' && line[p] <= 'z') || isDigit(line[p]) || line[p] == '-'))
            ++p;
        immutable size_t keyEnd = p;
        while (p < line.length && (line[p] == ' ' || line[p] == '\t'))
            ++p;
        if (keyEnd == keyStart || p >= line.length || line[p] != '=')
            fail(file, ln, cast(int) keyStart + 1, "bad-syntax");
        ++p;
        const key = line[keyStart .. keyEnd].to!string;
        // value: rest of line, trimmed
        size_t vs = p;
        while (vs < line.length && (line[vs] == ' ' || line[vs] == '\t'))
            ++vs;
        size_t ve = line.length;
        while (ve > vs && (line[ve - 1] == ' ' || line[ve - 1] == '\t'))
            --ve;
        const value = line[vs .. ve];
        immutable int vcol = cast(int) vs + 1;

        bool known = false;
        foreach (k; allKeys)
            if (k == key)
            {
                known = true;
                break;
            }
        if (!known)
            fail(file, ln, cast(int) keyStart + 1, "unknown-setting");
        if (key in assigned)
            fail(file, ln, cast(int) keyStart + 1, "duplicate-setting");
        assigned[key] = true;
        assign(s, key, value, ln, vcol);
        switch (key)
        {
        case "page-width", "page-height", "margin-top", "margin-bottom", "margin-left", "margin-right":
            geoLine = ln;
            geoCol = vcol;
            break;
        default:
            break;
        }
    }

    if ("footer-baseline" !in assigned)
        s.footerBaseline = s.pageHeight - 36_000;
    if ("footnote-max-height" !in assigned)
        s.footnoteMaxHeight = s.bodyHeight / 2;
    if ("header-left-even" !in assigned) s.headerLeftEven = s.headerLeft;
    if ("header-center-even" !in assigned) s.headerCenterEven = s.headerCenter;
    if ("header-right-even" !in assigned) s.headerRightEven = s.headerRight;
    if ("footer-left-even" !in assigned) s.footerLeftEven = s.footerLeft;
    if ("footer-center-even" !in assigned) s.footerCenterEven = s.footerCenter;
    if ("footer-right-even" !in assigned) s.footerRightEven = s.footerRight;

    if (s.bodyWidth < 36_000 || s.bodyHeight < 36_000)
        fail(file, geoLine, geoCol, "bad-value");
    return s;
}

private void assign(ref Settings s, const(char)[] key, const(dchar)[] value, int ln, int vcol)
{
    enum file = "settings.cfg";
    sw: switch (key)
    {
        static foreach (name; FieldNameTuple!Settings)
        {
            static foreach (uda; __traits(getAttributes, __traits(getMember, Settings, name)))
            {
                case uda.key:
                    {
                        alias T = typeof(__traits(getMember, Settings, name));
                        static if (is(typeof(uda) == Len))
                        {
                            long v;
                            if (!parseLength(value, v))
                                fail(file, ln, vcol, "bad-length");
                            if (v < uda.lo || v > uda.hi)
                                fail(file, ln, vcol, "bad-value");
                            __traits(getMember, s, name) = v;
                        }
                        else static if (is(typeof(uda) == Int))
                        {
                            long v;
                            if (!parseInteger(value, v))
                                fail(file, ln, vcol, "bad-integer");
                            if (v < uda.lo || v > uda.hi)
                                fail(file, ln, vcol, "bad-value");
                            __traits(getMember, s, name) = v;
                        }
                        else static if (is(typeof(uda) == Flag))
                        {
                            if (value == "on"d)
                                __traits(getMember, s, name) = true;
                            else if (value == "off"d)
                                __traits(getMember, s, name) = false;
                            else
                                fail(file, ln, vcol, "bad-boolean");
                        }
                        else static if (is(typeof(uda) == Choice))
                        {
                            bool ok = false;
                            foreach (m; EnumMembers!T)
                            {
                                if (value == m.to!string.to!dstring)
                                {
                                    __traits(getMember, s, name) = m;
                                    ok = true;
                                }
                            }
                            if (!ok)
                                fail(file, ln, vcol, uda.code);
                        }
                        else static if (is(typeof(uda) == Txt))
                        {
                            auto t = parseText(value, file, ln, vcol);
                            static if (uda.plain)
                            {
                                dstring lit;
                                foreach (part; t)
                                {
                                    if (part.isPlaceholder)
                                        fail(file, ln, vcol, "bad-value");
                                    lit ~= part.literal;
                                }
                                static if (uda.maxLen != 0)
                                {
                                    if (lit.length < 1 || lit.length > uda.maxLen)
                                        fail(file, ln, vcol, "bad-value");
                                    foreach (c; lit)
                                        if (c == ' ')
                                            fail(file, ln, vcol, "bad-value");
                                }
                                __traits(getMember, s, name) = lit;
                            }
                            else
                                __traits(getMember, s, name) = t;
                        }
                        break sw;
                    }
            }
        }
    default:
        assert(0, "unreachable: key was checked");
    }
}

/// Number of settings keys (126).
size_t settingsKeyCount() pure nothrow @safe @nogc
{
    return allKeys.length;
}

unittest
{
    assert(settingsKeyCount == 126);
    auto s = parseSettings("");
    assert(s.footerBaseline == 756_000 && s.footnoteMaxHeight == 324_000);
    s = parseSettings("page-height = 200pt\n# comment\n  tolerance\t=  5  \nalign=left\n");
    assert(s.footerBaseline == 164_000 && s.tolerance == 5 && s.align_ == Align.left);
}

unittest
{
    import std.exception : collectException;

    auto e = collectException!TypesetError(parseSettings("page-width = 200pt\nmargin-left = 20px\n"));
    assert(e !is null && e.diagnostic.toString == "settings.cfg:2:15: bad-length");
    e = collectException!TypesetError(parseSettings("header-left = \\{page}\n"));
    assert(e.diagnostic.toString == "settings.cfg:1:21: stray-brace");
    e = collectException!TypesetError(parseSettings("tolerance = 1\ntolerance = 2\n"));
    assert(e.diagnostic.toString == "settings.cfg:2:1: duplicate-setting");
    e = collectException!TypesetError(parseSettings("page-width = 40pt\nmargin-left=2pt\n"));
    assert(e.diagnostic.toString == "settings.cfg:2:13: bad-value");
}
