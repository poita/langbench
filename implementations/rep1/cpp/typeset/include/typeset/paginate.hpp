// Page breaking: turns a vertical list into pages of placed items.
#pragma once

#include <string>
#include <vector>

#include "typeset/layout.hpp"

namespace typeset {

enum class Region { Header = 0, Float = 1, Body = 2, Footnote = 3, Footer = 4 };

/// One placed output item (a `text`, `rule` or `box` line of layout.txt).
struct OutItem {
    enum Kind { Text = 0, RuleItem = 1, BoxItem = 2 };
    Kind kind = Text;
    Region region = Region::Body;
    int face = 0;
    i64 size = 0;
    i64 x = 0, y = 0;
    i64 width = 0;
    i64 height = 0;  ///< rule thickness or box height
    std::string text;
};

/// A paginated page: body/float/footnote items and the running-head state.
struct PageRecord {
    std::vector<OutItem> items;
    int chapter = -1;  ///< heading index of the current `@h1`, or -1
    int section = -1;  ///< heading index of the current `@h2`, or -1
};

/// What a pagination run reads and updates.
struct PaginateInput {
    const VList& list;
    const std::vector<FigureBlock>* figures = nullptr;                    ///< null: no figures
    const std::vector<std::vector<PlacedLine>>* footnotes = nullptr;      ///< null: no footnotes
    std::vector<HeadingInfo>* headings = nullptr;                         ///< pages are recorded here
};

/// Paginate a vertical list (body or table of contents).
std::vector<PageRecord> paginate(const Settings& settings, const FontSet& fonts, Stats& stats, const PaginateInput& in);

}  // namespace typeset
