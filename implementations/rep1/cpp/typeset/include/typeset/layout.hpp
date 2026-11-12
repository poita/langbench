// Block layout: walks the document tree and produces the vertical list.
#pragma once

#include <string>
#include <vector>

#include "typeset/document.hpp"
#include "typeset/hlist.hpp"
#include "typeset/linebreak.hpp"

namespace typeset {

/// A line of a table cell or figure caption, placed relative to its block's top.
struct RowLine {
    PlacedLine line;
    i64 baselineOffset = 0;
};

/// One table row: its height and the lines of all its cells.
struct Row {
    i64 height = 0;
    std::vector<RowLine> lines;
};

/// An item of a vertical list.
struct VItem {
    enum Kind : unsigned char { Line, Glue, Rule, RowItem, FloatMark, ForceBreak };
    Kind kind = Glue;
    i64 height = 0;  ///< Glue height; Rule thickness
    i64 x = 0, width = 0;  ///< Rule
    int index = -1;  ///< Line: arena index; RowItem: row index; FloatMark: figure index
    int group = 0;   ///< group id (Line)
    int k = 0, n = 0;  ///< 1-based index in the group and group size (Line)
    bool heading = false;  ///< group kind `heading`
    int headingId = -1;    ///< Line: heading whose first line this is
    i64 leading = 0;       ///< Line
};

/// A vertical list with the storage its items point into.
struct VList {
    std::vector<VItem> items;
    std::vector<PlacedLine> lines;
    std::vector<Row> rows;
};

/// What the table of contents and running headers need to know about a heading.
struct HeadingInfo {
    int level = 1;
    std::string number;  ///< number string, empty if unnumbered
    std::string plain;   ///< plain text
    bool inToc = false;
    int page = 0;        ///< 1-based body page of its first line (set by pagination)
};

/// A figure block, laid out once: positions are relative to its top.
struct FigureBlock {
    i64 height = 0;       ///< height of the whole block (frame, caption)
    i64 frameHeight = 0;  ///< the `height` attribute: the frame
    bool frame = false;
    i64 x = 0, width = 0;
    std::vector<RowLine> caption;
};

/// Everything the body layout produces.
struct BodyLayout {
    VList list;
    std::vector<HeadingInfo> headings;
    std::vector<FigureBlock> figures;
    std::vector<std::vector<PlacedLine>> footnoteLines;  ///< footnote n is [n-1]
};

/// One table-of-contents entry.
struct TocEntry {
    int level = 1;
    std::string number, plain, pageLabel;
};

/// Lays documents out. Holds the shared configuration and statistics sink.
class Layouter {
public:
    Layouter(const Settings& settings, const FontSet& fonts, const PatternSet& patterns, Stats& stats)
        : s_(settings), fonts_(fonts), builder_(settings, fonts, patterns), stats_(stats) {}

    /// Lay out the document body, its footnotes and its figures.
    BodyLayout layoutBody(const Document& doc);

    /// Lay out the table of contents for the given entries.
    VList layoutToc(const std::string& title, const std::vector<TocEntry>& entries);

private:
    struct Registers {
        i64 pendingMax = 0, pendingAdd = 0;
        bool started = false;
    };

    const Settings& s_;
    const FontSet& fonts_;
    HListBuilder builder_;
    Stats& stats_;

    // Per-vertical-list state
    VList* out_ = nullptr;
    BodyLayout* body_ = nullptr;
    Registers reg_;
    int nextGroup_ = 1;
    int counters_[4] = {0, 0, 0, 0};

    Context rootContext() const;
    void resetRegisters() { reg_ = Registers{}; }
    void pushGlue(i64 h);
    template <class F>
    void leaf(i64 before, i64 after, F&& emit);
    void pushGroup(std::vector<PlacedLine> lines, bool heading, int headingId, i64 leading);
    int addLine(PlacedLine line);

    void walk(const std::vector<std::unique_ptr<Block>>& blocks, const Context& ctx, int listDepth);
    void walkBlock(const Block& b, const Context& ctx, int listDepth);
    void walkList(const Block& b, const Context& ctx, int listDepth);
    void walkHeading(const Block& b, const Context& ctx);
    void walkPre(const Block& b, const Context& ctx);
    void walkTable(const Block& b, const Context& ctx);
    void walkFigure(const Block& b);
    void forceBreak();
    static i64 clampMeasure(i64 m) { return m < 1000 ? 1000 : m; }
};

}  // namespace typeset
