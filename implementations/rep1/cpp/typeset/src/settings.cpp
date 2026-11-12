#include "typeset/settings.hpp"

#include <functional>
#include <limits>
#include <unordered_map>
#include <unordered_set>

namespace typeset {

namespace {

constexpr i64 kBig = std::numeric_limits<i64>::max();

// Digits -> value, saturating far below overflow so range checks still work.
bool readDigits(std::string_view s, std::size_t& i, i64& out, std::size_t& count) {
    out = 0;
    count = 0;
    while (i < s.size() && s[i] >= '0' && s[i] <= '9') {
        if (out < 1000000000000000000LL / 10) out = out * 10 + (s[i] - '0');
        else out = 4000000000000000000LL;
        ++i;
        ++count;
    }
    return count > 0;
}

}  // namespace

std::optional<i64> parseLength(std::string_view s) {
    std::size_t i = 0;
    bool neg = false;
    if (i < s.size() && s[i] == '-') { neg = true; ++i; }
    i64 whole;
    std::size_t n;
    if (!readDigits(s, i, whole, n)) return std::nullopt;
    i64 frac = 0;
    std::size_t k = 0;
    if (i < s.size() && s[i] == '.') {
        ++i;
        std::size_t start = i;
        if (!readDigits(s, i, frac, k)) return std::nullopt;
        (void)start;
        if (k > 3) return std::nullopt;
    }
    std::string_view unit = s.substr(i);
    i64 unitMp;
    if (unit.empty()) unitMp = 1;
    else if (unit == "pt") unitMp = 1000;
    else if (unit == "mm") unitMp = 2835;
    else if (unit == "cm") unitMp = 28350;
    else if (unit == "in") unitMp = 72000;
    else if (unit == "pc") unitMp = 12000;
    else return std::nullopt;
    i64 pow = 1;
    for (std::size_t j = 0; j < k; ++j) pow *= 10;
    __int128 v = (static_cast<__int128>(whole) * pow + frac) * unitMp / pow;
    if (v > 4000000000000000000LL) v = 4000000000000000000LL;
    i64 r = static_cast<i64>(v);
    return neg ? -r : r;
}

std::optional<i64> parseInteger(std::string_view s) {
    std::size_t i = 0;
    bool neg = false;
    if (i < s.size() && s[i] == '-') { neg = true; ++i; }
    i64 v;
    std::size_t n;
    if (!readDigits(s, i, v, n) || i != s.size()) return std::nullopt;
    return neg ? -v : v;
}

namespace {

struct ValueError {
    const char* code;
    std::size_t offset;  // byte offset inside the value
};

bool isKeyChar(char c) { return (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-'; }

Text parseText(std::string_view v) {
    static const std::unordered_set<std::string> names = {"page", "pages", "title", "author",
                                                          "date", "chapter", "section"};
    Text out;
    std::string lit;
    auto flush = [&] {
        if (!lit.empty()) out.push_back({false, lit});
        lit.clear();
    };
    std::size_t i = 0;
    while (i < v.size()) {
        char c = v[i];
        if (c == '\\') {
            if (i + 1 >= v.size() || (v[i + 1] != '{' && v[i + 1] != '}' && v[i + 1] != '\\'))
                throw ValueError{"bad-escape", i};
            lit += v[i + 1];
            i += 2;
        } else if (c == '{') {
            std::size_t close = v.find('}', i + 1);
            if (close == std::string_view::npos) throw ValueError{"unknown-placeholder", i};
            std::string name(v.substr(i + 1, close - i - 1));
            if (!names.count(name)) throw ValueError{"unknown-placeholder", i};
            flush();
            out.push_back({true, name});
            i = close + 1;
        } else if (c == '}') {
            throw ValueError{"stray-brace", i};
        } else {
            lit += c;
            ++i;
        }
    }
    flush();
    return out;
}

bool hasPlaceholder(const Text& t) {
    for (const auto& p : t)
        if (p.placeholder) return true;
    return false;
}

std::string literalOf(const Text& t) {
    std::string s;
    for (const auto& p : t) s += p.text;
    return s;
}

using Apply = std::function<void(Settings&, std::string_view)>;

struct Registry {
    std::unordered_map<std::string, Apply> keys;
    std::array<bool, SlotCount> evenAssigned{};
    bool footerBaselineSet = false, footnoteMaxHeightSet = false;

    void length(const std::string& key, std::function<i64&(Settings&)> ref, i64 lo, i64 hi = kBig) {
        keys[key] = [=](Settings& s, std::string_view v) {
            auto n = parseLength(v);
            if (!n) throw ValueError{"bad-length", 0};
            if (*n < lo || *n > hi) throw ValueError{"bad-value", 0};
            ref(s) = *n;
        };
    }
    void integer(const std::string& key, std::function<i64&(Settings&)> ref, i64 lo, i64 hi) {
        keys[key] = [=](Settings& s, std::string_view v) {
            auto n = parseInteger(v);
            if (!n) throw ValueError{"bad-integer", 0};
            if (*n < lo || *n > hi) throw ValueError{"bad-value", 0};
            ref(s) = *n;
        };
    }
    void boolean(const std::string& key, std::function<bool&(Settings&)> ref) {
        keys[key] = [=](Settings& s, std::string_view v) {
            if (v == "on") ref(s) = true;
            else if (v == "off") ref(s) = false;
            else throw ValueError{"bad-boolean", 0};
        };
    }
    void alignment(const std::string& key, std::function<Align&(Settings&)> ref) {
        keys[key] = [=](Settings& s, std::string_view v) {
            if (v == "justify") ref(s) = Align::Justify;
            else if (v == "left") ref(s) = Align::Left;
            else if (v == "right") ref(s) = Align::Right;
            else if (v == "center") ref(s) = Align::Center;
            else throw ValueError{"bad-enum", 0};
        };
    }
    void family(const std::string& key, std::function<Family&(Settings&)> ref) {
        keys[key] = [=](Settings& s, std::string_view v) {
            if (v == "serif") ref(s) = Family::Serif;
            else if (v == "sans") ref(s) = Family::Sans;
            else if (v == "mono") ref(s) = Family::Mono;
            else throw ValueError{"unknown-font", 0};
        };
    }
    void text(const std::string& key, std::function<void(Settings&, Text)> set) {
        keys[key] = [=](Settings& s, std::string_view v) { set(s, parseText(v)); };
    }
};

#define LEN(key, field, ...) r.length(key, [](Settings& s) -> i64& { return s.field; }, __VA_ARGS__)
#define INT(key, field, lo, hi) r.integer(key, [](Settings& s) -> i64& { return s.field; }, lo, hi)
#define BOOL(key, field) r.boolean(key, [](Settings& s) -> bool& { return s.field; })
#define ALIGN(key, field) r.alignment(key, [](Settings& s) -> Align& { return s.field; })
#define FAMILY(key, field) r.family(key, [](Settings& s) -> Family& { return s.field; })

void buildRegistry(Registry& r) {
    LEN("page-width", pageWidth, 36000);
    LEN("page-height", pageHeight, 36000);
    LEN("margin-top", marginTop, 0);
    LEN("margin-bottom", marginBottom, 0);
    LEN("margin-left", marginLeft, 0);
    LEN("margin-right", marginRight, 0);
    LEN("header-baseline", headerBaseline, 0);
    LEN("footer-baseline", footerBaseline, 0);
    INT("page-start", pageStart, 1, 3000);

    FAMILY("body-font", bodyFont);
    LEN("body-size", bodySize, 1000, 200000);
    LEN("leading", leading, 1000);
    LEN("line-skip", lineSkip, 0);
    ALIGN("align", align);
    LEN("par-indent", parIndent, 0);
    LEN("par-space", parSpace, 0);

    INT("tolerance", tolerance, 0, 10000);
    INT("line-penalty", linePenalty, 0, 10000);
    INT("hyphen-penalty", hyphenPenalty, -9999, 9999);
    INT("ex-hyphen-penalty", exHyphenPenalty, -9999, 9999);
    INT("adj-demerits", adjDemerits, 0, 1000000);
    INT("double-hyphen-demerits", doubleHyphenDemerits, 0, 1000000);
    INT("final-hyphen-demerits", finalHyphenDemerits, 0, 1000000);
    INT("ragged-stretch", raggedStretch, 0, 100);
    BOOL("hyphenate", hyphenate);
    r.keys["hyphen-patterns"] = [](Settings& s, std::string_view v) {
        if (v != "english" && v != "minimal") throw ValueError{"unknown-patterns", 0};
        s.hyphenPatterns = std::string(v);
    };

    FAMILY("heading-font", headingFont);
    BOOL("heading-bold", headingBold);
    BOOL("heading-italic", headingItalic);
    ALIGN("heading-align", headingAlign);
    BOOL("heading-number", headingNumber);
    LEN("heading-number-gap", headingNumberGap, 0);
    BOOL("h1-newpage", h1Newpage);
    for (int i = 0; i < 4; ++i) {
        std::string h = "h" + std::to_string(i + 1);
        r.length(h + "-size", [i](Settings& s) -> i64& { return s.hSize[i]; }, 1000, 200000);
        r.length(h + "-leading", [i](Settings& s) -> i64& { return s.hLeading[i]; }, 1000);
        r.length(h + "-space-before", [i](Settings& s) -> i64& { return s.hSpaceBefore[i]; }, 0);
        r.length(h + "-space-after", [i](Settings& s) -> i64& { return s.hSpaceAfter[i]; }, 0);
    }

    LEN("list-indent", listIndent, 0);
    LEN("list-marker-gap", listMarkerGap, 0);
    LEN("list-space", listSpace, 0);
    LEN("list-item-space", listItemSpace, 0);
    LEN("quote-indent", quoteIndent, 0);
    LEN("quote-space", quoteSpace, 0);
    FAMILY("pre-font", preFont);
    LEN("pre-size", preSize, 1000, 200000);
    LEN("pre-leading", preLeading, 1000);
    LEN("pre-indent", preIndent, 0);
    LEN("pre-space", preSpace, 0);

    LEN("table-col-gap", tableColGap, 0);
    LEN("table-row-space", tableRowSpace, 0);
    LEN("table-rule-space", tableRuleSpace, 0);
    LEN("table-rule-thickness", tableRuleThickness, 1);
    LEN("table-space", tableSpace, 0);
    LEN("table-leading", tableLeading, 1000);
    LEN("rule-thickness", ruleThickness, 1);
    LEN("rule-space", ruleSpace, 0);

    FAMILY("footnote-font", footnoteFont);
    LEN("footnote-size", footnoteSize, 1000, 200000);
    LEN("footnote-leading", footnoteLeading, 1000);
    LEN("footnote-indent", footnoteIndent, 0);
    LEN("footnote-mark-gap", footnoteMarkGap, 0);
    LEN("footnote-mark-size", footnoteMarkSize, 1000, 200000);
    LEN("footnote-mark-raise", footnoteMarkRaise, 0);
    LEN("footnote-item-space", footnoteItemSpace, 0);
    LEN("footnote-rule-width", footnoteRuleWidth, 0);
    LEN("footnote-rule-thickness", footnoteRuleThickness, 1);
    LEN("footnote-space-before", footnoteSpaceBefore, 0);
    LEN("footnote-space-after", footnoteSpaceAfter, 0);
    INT("footnote-min-split", footnoteMinSplit, 1, 100);
    LEN("footnote-max-height", footnoteMaxHeight, 1000);
    LEN("mark-size", markSize, 1000, 200000);
    LEN("mark-raise", markRaise, 0);

    LEN("figure-width", figureWidth, 0);
    BOOL("figure-frame", figureFrame);
    FAMILY("figure-caption-font", figureCaptionFont);
    LEN("figure-caption-size", figureCaptionSize, 1000, 200000);
    LEN("figure-caption-leading", figureCaptionLeading, 1000);
    ALIGN("figure-caption-align", figureCaptionAlign);
    LEN("figure-caption-space", figureCaptionSpace, 0);
    r.text("figure-caption-prefix", [](Settings& s, Text t) {
        if (hasPlaceholder(t)) throw ValueError{"bad-value", 0};
        s.figureCaptionPrefix = literalOf(t);
    });
    LEN("figure-caption-gap", figureCaptionGap, 0);
    LEN("float-space-after", floatSpaceAfter, 0);
    LEN("float-min-body", floatMinBody, 0);

    INT("widows", widows, 1, 20);
    INT("orphans", orphans, 1, 20);
    BOOL("keep-with-next", keepWithNext);

    INT("toc-depth", tocDepth, 0, 4);
    FAMILY("toc-font", tocFont);
    LEN("toc-size", tocSize, 1000, 200000);
    LEN("toc-leading", tocLeading, 1000);
    LEN("toc-indent", tocIndent, 0);
    LEN("toc-number-gap", tocNumberGap, 0);
    LEN("toc-reserve", tocReserve, 0);
    r.text("toc-leader", [](Settings& s, Text t) {
        if (hasPlaceholder(t)) throw ValueError{"bad-value", 0};
        std::string lit = literalOf(t);
        std::size_t n = utf8Length(lit);
        if (n < 1 || n > 8 || lit.find(' ') != std::string::npos) throw ValueError{"bad-value", 0};
        s.tocLeader = lit;
    });
    LEN("toc-leader-gap", tocLeaderGap, 0);
    LEN("toc-entry-space", tocEntrySpace, 0);
    r.text("toc-title", [](Settings& s, Text t) {
        if (hasPlaceholder(t)) throw ValueError{"bad-value", 0};
        s.tocTitle = literalOf(t);
    });
    FAMILY("toc-title-font", tocTitleFont);
    LEN("toc-title-size", tocTitleSize, 1000, 200000);
    LEN("toc-title-space-after", tocTitleSpaceAfter, 0);

    FAMILY("header-font", headerFont);
    LEN("header-size", headerSize, 1000, 200000);
    static const char* const slotNames[SlotCount] = {"header-left", "header-center", "header-right",
                                                     "footer-left", "footer-center", "footer-right"};
    for (int i = 0; i < SlotCount; ++i) {
        r.text(slotNames[i], [i](Settings& s, Text t) { s.slotsOdd[i] = std::move(t); });
        std::string even = std::string(slotNames[i]) + "-even";
        r.text(even, [i](Settings& s, Text t) { s.slotsEven[i] = std::move(t); });
    }
}

}  // namespace

Settings Settings::parse(std::optional<std::string_view> source) {
    Settings s;
    Registry reg;
    buildRegistry(reg);
    std::unordered_set<std::string> assigned;
    std::array<bool, SlotCount> evenSet{};
    bool footerSet = false, maxHeightSet = false;
    int geomLine = 0, geomCol = 0;
    static const std::unordered_set<std::string> geometryKeys = {
        "page-width", "page-height", "margin-top", "margin-bottom", "margin-left", "margin-right"};

    if (source) {
        std::string_view text = *source;
        std::size_t pos = 0;
        int lineNo = 0;
        while (pos < text.size()) {
            std::size_t nl = text.find('\n', pos);
            std::string_view line = text.substr(pos, (nl == std::string_view::npos ? text.size() : nl) - pos);
            pos = nl == std::string_view::npos ? text.size() : nl + 1;
            ++lineNo;
            auto col = [&](std::size_t byte) { return static_cast<int>(utf8Length(line.substr(0, byte))) + 1; };
            auto fail = [&](std::size_t byte, const char* code) { throw Error("settings.cfg", lineNo, col(byte), code); };

            std::size_t i = line.find_first_not_of(" \t");
            if (i == std::string_view::npos || line[i] == '#') continue;
            std::size_t k = i;
            while (k < line.size() && isKeyChar(line[k])) ++k;
            std::size_t j = k;
            while (j < line.size() && (line[j] == ' ' || line[j] == '\t')) ++j;
            if (k == i || j >= line.size() || line[j] != '=') fail(i, "bad-syntax");
            std::string key(line.substr(i, k - i));
            auto it = reg.keys.find(key);
            if (it == reg.keys.end()) fail(i, "unknown-setting");
            if (!assigned.insert(key).second) fail(i, "duplicate-setting");

            std::size_t vs = j + 1;
            while (vs < line.size() && (line[vs] == ' ' || line[vs] == '\t')) ++vs;
            std::size_t ve = line.size();
            while (ve > vs && (line[ve - 1] == ' ' || line[ve - 1] == '\t')) --ve;
            std::string_view value = line.substr(vs, ve - vs);
            try {
                it->second(s, value);
            } catch (const ValueError& e) {
                fail(vs + e.offset, e.code);
            }
            if (geometryKeys.count(key)) {
                geomLine = lineNo;
                geomCol = col(vs);
            }
            if (key == "footer-baseline") footerSet = true;
            if (key == "footnote-max-height") maxHeightSet = true;
            for (int sl = 0; sl < SlotCount; ++sl)
                if (key.size() > 5 && key.compare(key.size() - 5, 5, "-even") == 0 &&
                    key == std::string(sl < 3 ? "header-" : "footer-") +
                               (sl % 3 == 0 ? "left" : sl % 3 == 1 ? "center" : "right") + "-even")
                    evenSet[sl] = true;
        }
    }

    if (s.bodyWidth() < 36000 || s.bodyHeight() < 36000)
        throw Error("settings.cfg", geomLine, geomCol, "bad-value");
    if (!footerSet) s.footerBaseline = s.pageHeight - 36000;
    if (!maxHeightSet) s.footnoteMaxHeight = floorDiv(s.bodyHeight(), 2);
    for (int sl = 0; sl < SlotCount; ++sl)
        if (!evenSet[sl]) s.slotsEven[sl] = s.slotsOdd[sl];
    return s;
}

}  // namespace typeset
