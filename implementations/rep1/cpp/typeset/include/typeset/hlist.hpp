// Horizontal lists: items, hyphenation, and the builder that turns inline
// units into BOX / GLUE / PENALTY items.
#pragma once

#include <string>
#include <vector>

#include "typeset/document.hpp"
#include "typeset/font.hpp"
#include "typeset/hyphenation.hpp"
#include "typeset/settings.hpp"

namespace typeset {

/// The context a horizontal list is built in.
struct Context {
    Family family = Family::Serif;
    bool bold = false, italic = false;
    i64 size = 10000;
    i64 leading = 12000;
    i64 left = 0;
    i64 measure = 0;
    i64 firstIndent = 0;
    Align align = Align::Justify;
    bool hyphenate = true;
};

/// One item of a horizontal list.
struct Item {
    enum Kind : unsigned char { Box, Glue, Penalty };
    Kind kind = Box;
    bool rigid = false;     ///< Box without text or face
    bool infinite = false;  ///< Glue with infinite stretch
    bool flagged = false;   ///< Penalty
    int face = -1;
    i64 size = 0, raise = 0;
    i64 width = 0;                     ///< box width, glue natural width
    i64 stretch = 0, shrink = 0;       ///< glue
    i64 penalty = 0;                   ///< penalty value
    int fragment = -1;                 ///< fragment id (boxes and pre-break text)
    int footnote = 0;                  ///< footnote number carried by a mark box
    std::string text;                  ///< box text
    std::string preText;               ///< penalty: pre-break text
    i64 preWidth = 0;
};

/// A horizontal list together with the prefix sums that make measuring any
/// candidate line O(1).
class HList {
public:
    Context context;
    std::vector<Item> items;
    std::vector<int> breakpoints;  ///< item indices of breakpoints (excluding the notional start)

    /// Totals of the line between breakpoints `a` (0 = list start) and `b`.
    struct Measure {
        i64 width = 0;       ///< W, including pre-break text of `b`
        i64 widthNoPre = 0;  ///< W without the pre-break text
        i64 stretch = 0;
        i64 shrink = 0;
        bool infinite = false;
    };

    /// Compute prefix sums and breakpoints; call once after filling `items`.
    void finish();

    /// The line from breakpoint `a` to breakpoint `b` (a < b), O(1).
    Measure measure(int a, int b) const;

    /// Index of the first item of the line starting after breakpoint `a`
    /// (leading finite glue removed, capped at `b`).
    int lineStart(int a, int b) const;

    int finalIndex() const { return static_cast<int>(items.size()) - 1; }

    /// Natural width of the whole list on one line (excluding the final glue).
    i64 naturalWidth() const;
    /// Widest line any pair of consecutive breakpoints could produce.
    i64 minWidth() const;

private:
    std::vector<i64> cumW_, cumY_, cumZ_;
    std::vector<int> cumInf_;
    std::vector<int> skipGlue_;  ///< first index >= i that is not a finite glue
};

/// Builds horizontal lists from inline units.
class HListBuilder {
public:
    HListBuilder(const Settings& settings, const FontSet& fonts, const PatternSet& patterns)
        : settings_(settings), fonts_(fonts), patterns_(patterns) {}

    /// Build the list for `units` (whose style ids refer to `styles`) in `ctx`.
    HList build(const std::vector<Unit>& units, const std::vector<StyleNode>& styles, const Context& ctx) const;

    /// Convenience: build from an `InlineText`.
    HList build(const InlineText& text, const Context& ctx) const { return build(text.units, text.styles, ctx); }

    /// A list holding a single box with all of `utf8` (spaces included) and no
    /// hyphenation: one `@pre` line.
    HList buildVerbatim(std::string_view utf8, const Context& ctx) const;

    /// Face of the context's own initial style.
    static int contextFace(const Context& ctx) { return faceIndex(ctx.family, ctx.bold, ctx.italic); }

private:
    const Settings& settings_;
    const FontSet& fonts_;
    const PatternSet& patterns_;
};

/// Hyphenation points of one fragment, as (position, penalty-kind) pairs.
struct HyphenPoint {
    std::size_t pos;
    bool exHyphen;  ///< true: break after a literal `-` (no pre-break text, `ex-hyphen-penalty`);
                    ///< false: Liang or `\-` point (pre-break "-", `hyphen-penalty`)
};

/// Compute the hyphenation points of a fragment's characters (Liang rules,
/// explicit points, core hyphens); `discretionary` are positions of `\-`.
std::vector<HyphenPoint> hyphenationPoints(const std::u32string& chars, const std::vector<std::size_t>& discretionary,
                                           const PatternSet& patterns);

}  // namespace typeset
