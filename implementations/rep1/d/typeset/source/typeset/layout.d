/**
 * The result of typesetting: pages of placed items, the statistics report,
 * and their textual file formats (`layout.txt`, `report.txt`).
 */
module typeset.layout;

import std.algorithm : sort;
import std.array : appender;
import std.conv : to;

/// Page region of a placed item; the declaration order is the sort rank.
enum Region : ubyte
{
    header,
    float_,
    body_,
    footnote,
    footer
}

/// Kind of a placed item; the declaration order is the sort rank.
enum ItemKind : ubyte
{
    text,
    rule,
    box
}

/// One item on a page.
struct PlacedItem
{
    Region region;
    ItemKind kind;
    string face; /// text only
    long size; /// text only
    long x, y; /// text: left edge and baseline; rule/box: left edge and top
    long width;
    long height; /// rule thickness or box height
    string text; /// text only

    /// The item as an (unindented) `layout.txt` line.
    string format() const
    {
        static immutable regionNames = ["header", "float", "body", "footnote", "footer"];
        final switch (kind)
        {
        case ItemKind.text:
            return "text " ~ regionNames[region] ~ " " ~ face ~ " " ~ size.to!string ~ " " ~ x.to!string ~ " "
                ~ y.to!string ~ " " ~ width.to!string ~ " \"" ~ escape(text) ~ "\"";
        case ItemKind.rule:
            return "rule " ~ regionNames[region] ~ " " ~ x.to!string ~ " " ~ y.to!string ~ " "
                ~ width.to!string ~ " " ~ height.to!string;
        case ItemKind.box:
            return "box " ~ regionNames[region] ~ " " ~ x.to!string ~ " " ~ y.to!string ~ " "
                ~ width.to!string ~ " " ~ height.to!string;
        }
    }
}

private string escape(string s) pure @safe
{
    string r;
    foreach (c; s)
    {
        if (c == '\\')
            r ~= "\\\\";
        else if (c == '"')
            r ~= "\\\"";
        else
            r ~= c;
    }
    return r;
}

/// One output page.
struct Page
{
    string label;
    PlacedItem[] items; /// in output (sorted) order once the layout is finished
}

/// The complete placement of a document.
struct Layout
{
    long pageWidth, pageHeight;
    long bodyX, bodyY, bodyWidth, bodyHeight;
    Page[] pages;

    /// Sorts every page's items into output order.
    void sortItems()
    {
        foreach (ref p; pages)
        {
            static struct Keyed
            {
                PlacedItem item;
                string line;
            }

            Keyed[] k;
            foreach (ref it; p.items)
                k ~= Keyed(it, it.format());
            k.sort!((a, b) {
                if (a.item.region != b.item.region)
                    return a.item.region < b.item.region;
                if (a.item.y != b.item.y)
                    return a.item.y < b.item.y;
                if (a.item.x != b.item.x)
                    return a.item.x < b.item.x;
                if (a.item.kind != b.item.kind)
                    return a.item.kind < b.item.kind;
                return a.line < b.line;
            });
            foreach (i, ref e; k)
                p.items[i] = e.item;
        }
    }

    /// The `layout.txt` file contents.
    string toText() const
    {
        auto o = appender!string;
        o ~= "layout 1\npages " ~ pages.length.to!string ~ "\n";
        foreach (i, ref p; pages)
        {
            o ~= "page " ~ (i + 1).to!string ~ " " ~ p.label ~ " " ~ pageWidth.to!string ~ " "
                ~ pageHeight.to!string ~ " " ~ bodyX.to!string ~ " " ~ bodyY.to!string ~ " "
                ~ bodyWidth.to!string ~ " " ~ bodyHeight.to!string ~ "\n";
            foreach (ref it; p.items)
            {
                o ~= "  ";
                o ~= it.format();
                o ~= "\n";
            }
        }
        return o.data;
    }
}

/// The statistics of `report.txt`.
struct Report
{
    long pages, frontPages, bodyPages, lines, paragraphs, headings, tables, figures, footnotes;
    long footnoteSplitLines, hyphenatedLines, overfullLines, emergencyLists, totalDemerits;

    /// The `report.txt` file contents.
    string toText() const
    {
        return "report 1\npages " ~ pages.to!string ~ "\nfront-pages " ~ frontPages.to!string
            ~ "\nbody-pages " ~ bodyPages.to!string ~ "\nlines " ~ lines.to!string
            ~ "\nparagraphs " ~ paragraphs.to!string ~ "\nheadings " ~ headings.to!string
            ~ "\ntables " ~ tables.to!string ~ "\nfigures " ~ figures.to!string
            ~ "\nfootnotes " ~ footnotes.to!string ~ "\nfootnote-split-lines " ~ footnoteSplitLines.to!string
            ~ "\nhyphenated-lines " ~ hyphenatedLines.to!string ~ "\noverfull-lines " ~ overfullLines.to!string
            ~ "\nemergency-lists " ~ emergencyLists.to!string ~ "\ntotal-demerits " ~ totalDemerits.to!string ~ "\n";
    }
}

unittest
{
    PlacedItem t;
    t.kind = ItemKind.text;
    t.region = Region.body_;
    t.face = "serif";
    t.size = 10_000;
    t.x = 38_000;
    t.y = 27_310;
    t.width = 15_630;
    t.text = "The \"q\"\\";
    assert(t.format() == `text body serif 10000 38000 27310 15630 "The \"q\"\\"`);
}
