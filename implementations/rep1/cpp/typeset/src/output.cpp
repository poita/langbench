#include "typeset/output.hpp"

#include <algorithm>
#include <tuple>

namespace typeset {

namespace {
const char* regionName(Region r) {
    switch (r) {
        case Region::Header: return "header";
        case Region::Float: return "float";
        case Region::Body: return "body";
        case Region::Footnote: return "footnote";
        case Region::Footer: return "footer";
    }
    return "body";
}
}  // namespace

std::string formatItem(const OutItem& it) {
    std::string out;
    switch (it.kind) {
        case OutItem::Text:
            out = std::string("text ") + regionName(it.region) + " " + faceName(it.face) + " " + std::to_string(it.size) + " " +
                  std::to_string(it.x) + " " + std::to_string(it.y) + " " + std::to_string(it.width) + " \"";
            for (char c : it.text) {
                if (c == '\\') out += "\\\\";
                else if (c == '"') out += "\\\"";
                else out += c;
            }
            out += "\"";
            break;
        case OutItem::RuleItem:
            out = std::string("rule ") + regionName(it.region) + " " + std::to_string(it.x) + " " + std::to_string(it.y) + " " +
                  std::to_string(it.width) + " " + std::to_string(it.height);
            break;
        case OutItem::BoxItem:
            out = std::string("box ") + regionName(it.region) + " " + std::to_string(it.x) + " " + std::to_string(it.y) + " " +
                  std::to_string(it.width) + " " + std::to_string(it.height);
            break;
    }
    return out;
}

std::string formatLayout(const std::vector<OutputPage>& pages, const Settings& s) {
    std::string out = "layout 1\npages " + std::to_string(pages.size()) + "\n";
    int index = 0;
    for (const OutputPage& page : pages) {
        ++index;
        out += "page " + std::to_string(index) + " " + page.label + " " + std::to_string(s.pageWidth) + " " +
               std::to_string(s.pageHeight) + " " + std::to_string(s.bodyX()) + " " + std::to_string(s.bodyY()) + " " +
               std::to_string(s.bodyWidth()) + " " + std::to_string(s.bodyHeight()) + "\n";
        struct Keyed {
            int region;
            i64 y, x;
            int kind;
            std::string line;
        };
        std::vector<Keyed> keyed;
        keyed.reserve(page.items.size());
        for (const OutItem& it : page.items)
            keyed.push_back({static_cast<int>(it.region), it.y, it.x, static_cast<int>(it.kind), formatItem(it)});
        std::sort(keyed.begin(), keyed.end(), [](const Keyed& a, const Keyed& b) {
            return std::tie(a.region, a.y, a.x, a.kind, a.line) < std::tie(b.region, b.y, b.x, b.kind, b.line);
        });
        for (const Keyed& k : keyed) out += "  " + k.line + "\n";
    }
    return out;
}

std::string formatReport(const Stats& st) {
    std::string out = "report 1\n";
    auto add = [&](const char* key, i64 v) { out += std::string(key) + " " + std::to_string(v) + "\n"; };
    add("pages", st.pages);
    add("front-pages", st.frontPages);
    add("body-pages", st.pages - st.frontPages);
    add("lines", st.lines);
    add("paragraphs", st.paragraphs);
    add("headings", st.headings);
    add("tables", st.tables);
    add("figures", st.figures);
    add("footnotes", st.footnotes);
    add("footnote-split-lines", st.footnoteSplitLines);
    add("hyphenated-lines", st.hyphenatedLines);
    add("overfull-lines", st.overfullLines);
    add("emergency-lists", st.emergencyLists);
    add("total-demerits", st.totalDemerits);
    return out;
}

}  // namespace typeset
