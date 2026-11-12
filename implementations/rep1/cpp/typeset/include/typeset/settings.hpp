// Layout settings: the `settings.cfg` parser and the resolved values.
#pragma once

#include <array>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

#include "typeset/error.hpp"
#include "typeset/font.hpp"
#include "typeset/util.hpp"

namespace typeset {

enum class Align { Justify, Left, Right, Center };

/// One piece of a header/footer text: literal characters or a `{name}` placeholder.
struct TextPart {
    bool placeholder = false;
    std::string text;  ///< the literal, or the placeholder name
};
using Text = std::vector<TextPart>;

/// Header/footer slot indices: header left/center/right, footer left/center/right.
enum Slot { HeaderLeft = 0, HeaderCenter, HeaderRight, FooterLeft, FooterCenter, FooterRight, SlotCount };

/// Every layout setting, in millipoints / plain integers / enums. The default
/// constructed value holds the documented defaults (derived defaults such as
/// `footerBaseline` are resolved by `Settings::parse`).
struct Settings {
    // Page geometry
    i64 pageWidth = 612000, pageHeight = 792000;
    i64 marginTop = 72000, marginBottom = 72000, marginLeft = 72000, marginRight = 72000;
    i64 headerBaseline = 36000, footerBaseline = 756000;
    i64 pageStart = 1;

    // Body text
    Family bodyFont = Family::Serif;
    i64 bodySize = 10000, leading = 12000, lineSkip = 1000;
    Align align = Align::Justify;
    i64 parIndent = 18000, parSpace = 0;

    // Line breaking
    i64 tolerance = 1000, linePenalty = 10, hyphenPenalty = 50, exHyphenPenalty = 50;
    i64 adjDemerits = 10000, doubleHyphenDemerits = 10000, finalHyphenDemerits = 5000;
    i64 raggedStretch = 3;
    bool hyphenate = true;
    std::string hyphenPatterns = "english";

    // Headings
    Family headingFont = Family::Sans;
    bool headingBold = true, headingItalic = false;
    Align headingAlign = Align::Left;
    bool headingNumber = true;
    i64 headingNumberGap = 6000;
    bool h1Newpage = false;
    std::array<i64, 4> hSize{20000, 14000, 12000, 11000};
    std::array<i64, 4> hLeading{24000, 17000, 14000, 13000};
    std::array<i64, 4> hSpaceBefore{18000, 14000, 12000, 11000};
    std::array<i64, 4> hSpaceAfter{9000, 7000, 6000, 5000};

    // Lists, quotes, preformatted text
    i64 listIndent = 18000, listMarkerGap = 4000, listSpace = 6000, listItemSpace = 0;
    i64 quoteIndent = 18000, quoteSpace = 6000;
    Family preFont = Family::Mono;
    i64 preSize = 9000, preLeading = 11000, preIndent = 0, preSpace = 6000;

    // Tables and rules
    i64 tableColGap = 8000, tableRowSpace = 2000, tableRuleSpace = 2000, tableRuleThickness = 400;
    i64 tableSpace = 6000, tableLeading = 12000;
    i64 ruleThickness = 500, ruleSpace = 6000;

    // Footnotes
    Family footnoteFont = Family::Serif;
    i64 footnoteSize = 8000, footnoteLeading = 10000, footnoteIndent = 10000;
    i64 footnoteMarkGap = 2000, footnoteMarkSize = 6000, footnoteMarkRaise = 2000;
    i64 footnoteItemSpace = 2000, footnoteRuleWidth = 120000, footnoteRuleThickness = 400;
    i64 footnoteSpaceBefore = 6000, footnoteSpaceAfter = 3000, footnoteMinSplit = 1;
    i64 footnoteMaxHeight = 0;  ///< default: body height div 2
    i64 markSize = 7000, markRaise = 3000;

    // Figures
    i64 figureWidth = 0;
    bool figureFrame = true;
    Family figureCaptionFont = Family::Serif;
    i64 figureCaptionSize = 9000, figureCaptionLeading = 11000;
    Align figureCaptionAlign = Align::Center;
    i64 figureCaptionSpace = 4000;
    std::string figureCaptionPrefix = "Figure";
    i64 figureCaptionGap = 4000, floatSpaceAfter = 12000, floatMinBody = 24000;

    // Page breaking
    i64 widows = 2, orphans = 2;
    bool keepWithNext = true;

    // Table of contents
    i64 tocDepth = 2;
    Family tocFont = Family::Serif;
    i64 tocSize = 10000, tocLeading = 14000, tocIndent = 18000, tocNumberGap = 6000, tocReserve = 30000;
    std::string tocLeader = ".";
    i64 tocLeaderGap = 3000, tocEntrySpace = 0;
    std::string tocTitle = "Contents";
    Family tocTitleFont = Family::Sans;
    i64 tocTitleSize = 20000, tocTitleSpaceAfter = 12000;

    // Running headers and footers
    Family headerFont = Family::Sans;
    i64 headerSize = 9000;
    std::array<Text, SlotCount> slotsOdd;   ///< `header-left` ... `footer-right`
    std::array<Text, SlotCount> slotsEven;  ///< the `-even` variants (resolved)

    // Derived page geometry
    i64 bodyX() const { return marginLeft; }
    i64 bodyY() const { return marginTop; }
    i64 bodyWidth() const { return pageWidth - marginLeft - marginRight; }
    i64 bodyHeight() const { return pageHeight - marginTop - marginBottom; }
    i64 bodyBottom() const { return bodyY() + bodyHeight(); }

    /// Parse the contents of a `settings.cfg` file (or nothing: all defaults).
    /// Throws `Error` (file "settings.cfg") at the first problem.
    static Settings parse(std::optional<std::string_view> source);
};

/// Parse a length literal (`2.5pt`, `-6pt`, `734`); nullopt when malformed.
std::optional<i64> parseLength(std::string_view text);

/// Parse an integer literal (`[-]?DIGITS`); nullopt when malformed.
std::optional<i64> parseInteger(std::string_view text);

}  // namespace typeset
