// Total-fit line breaking and line setting.
#pragma once

#include <string>
#include <vector>

#include "typeset/font.hpp"
#include "typeset/hlist.hpp"
#include "typeset/settings.hpp"

namespace typeset {

/// Counters reported in `report.txt`.
struct Stats {
    i64 pages = 0;
    i64 frontPages = 0;
    i64 lines = 0;
    i64 paragraphs = 0;
    i64 headings = 0;
    i64 tables = 0;
    i64 figures = 0;
    i64 footnotes = 0;
    i64 footnoteSplitLines = 0;
    i64 hyphenatedLines = 0;
    i64 overfullLines = 0;
    i64 emergencyLists = 0;
    i64 totalDemerits = 0;
};

/// The outcome of breaking one horizontal list.
struct BreakResult {
    std::vector<int> breaks;  ///< chosen breakpoint item indices, last one is the final breakpoint
    i64 demerits = 0;
    bool emergency = false;  ///< pass 2 was needed
};

/// Break `list` with the two-pass total-fit algorithm.
BreakResult breakIntoLines(const HList& list, const Settings& settings);

/// A run of text placed on a line. `x` is absolute; the output baseline is
/// the line's baseline minus `raise`.
struct Run {
    int face = 0;
    i64 size = 0;
    i64 x = 0;
    i64 raise = 0;
    i64 width = 0;
    std::string text;
};

/// One set line: its runs, vertical metrics and the footnotes it references.
struct PlacedLine {
    std::vector<Run> runs;
    std::vector<Run> extras;  ///< list marker, TOC leaders and labels (not counted as text of the line)
    i64 ascent = 0, depth = 0;
    i64 startX = 0, endX = 0;
    std::vector<int> footnotes;
};

/// Set the lines of `list` for the chosen `breaks`; updates the hyphenated
/// and overfull counters in `stats`.
std::vector<PlacedLine> setLines(const HList& list, const std::vector<int>& breaks, const FontSet& fonts, Stats& stats);

/// Break and set a list; accumulates total demerits, emergency lists and the
/// line counters in `stats`.
std::vector<PlacedLine> typesetList(const HList& list, const Settings& settings, const FontSet& fonts, Stats& stats);

}  // namespace typeset
