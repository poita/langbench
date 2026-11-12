#include "typeset/document.hpp"

#include <algorithm>
#include <cstring>

namespace typeset {

namespace {

constexpr const char* kFile = "document.cdx";

struct PChar {
    char32_t c;
    int line;
    int col;
};

/// A piece of a block's text: `text` starts at column `col` of source line `line`.
struct Seg {
    std::string text;
    int line;
    int col;
};

void appendChars(std::vector<PChar>& out, const Seg& seg) {
    int col = seg.col;
    for (char32_t c : utf8ToU32(seg.text)) out.push_back({c, seg.line, col++});
}

/// Join segments with one space (the joining space belongs to the earlier line).
std::vector<PChar> joinSegs(const std::vector<Seg>& segs) {
    std::vector<PChar> out;
    for (std::size_t i = 0; i < segs.size(); ++i) {
        if (i > 0) out.push_back({U' ', segs[i - 1].line, 0});
        appendChars(out, segs[i]);
    }
    return out;
}

[[noreturn]] void fail(int line, int col, const char* code) { throw Error(kFile, line, col, code); }

void stripGlue(InlineText& t) {
    while (!t.units.empty() && t.units.back().kind == Unit::Glue) t.units.pop_back();
    std::size_t k = 0;
    while (k < t.units.size() && t.units[k].kind == Unit::Glue) ++k;
    t.units.erase(t.units.begin(), t.units.begin() + k);
}

/// The inline scanner: recognises styles, escapes, footnotes, `~`, `\-` and
/// collapses spaces, reporting the first error in left-to-right order.
InlineText scanInline(const std::vector<PChar>& cs, bool allowFootnote, std::vector<InlineText>* footnotes) {
    struct Frame {
        char tag;
        std::size_t pos;
        int savedStyle;
        bool footnote;
    };
    InlineText main, fn;
    InlineText* cur = &main;
    int style = 0;
    std::vector<Frame> stack;
    bool inFootnote = false;
    std::size_t fnIndex = 0;

    auto err = [&](std::size_t idx, const char* code) { fail(cs[idx].line, cs[idx].col, code); };
    auto push = [&](Unit::Kind k, char32_t c) {
        Unit u;
        u.kind = k;
        u.c = c;
        u.style = style;
        cur->units.push_back(u);
    };

    const std::size_t n = cs.size();
    for (std::size_t i = 0; i < n; ++i) {
        char32_t c = cs[i].c;
        if (c == U'\\') {
            if (i + 1 >= n) err(i, "bad-escape");
            char32_t d = cs[i + 1].c;
            switch (d) {
                case U'{': case U'}': case U'|': case U'\\': case U'@': case U'~':
                    push(Unit::Char, d);
                    break;
                case U' ':
                    push(Unit::RigidSpace, 0);
                    break;
                case U'-':
                    push(Unit::Disc, 0);
                    break;
                default:
                    err(i, "bad-escape");
            }
            ++i;
        } else if (c == U'~') {
            push(Unit::RigidSpace, 0);
        } else if (c == U' ') {
            if (!cur->units.empty() && cur->units.back().kind != Unit::Glue) push(Unit::Glue, 0);
        } else if (c == U'{') {
            char32_t tag = i + 1 < n ? cs[i + 1].c : 0;
            bool ok = i + 2 < n && cs[i + 2].c == U'|' && tag < 128 && tag != 0 && std::strchr("bim+-n", static_cast<char>(tag));
            if (!ok) err(i, "unknown-inline");
            if (tag == U'n') {
                if (inFootnote) err(i, "nested-footnote");
                if (!allowFootnote || !footnotes) err(i, "footnote-not-allowed");
                footnotes->emplace_back();
                fnIndex = footnotes->size() - 1;
                Unit mark;
                mark.kind = Unit::Mark;
                mark.style = style;
                mark.footnote = static_cast<int>(footnotes->size());
                cur->units.push_back(mark);
                stack.push_back({'n', i, style, true});
                inFootnote = true;
                fn = InlineText{};
                cur = &fn;
                style = 0;
            } else {
                cur->styles.push_back({style, static_cast<char>(tag)});
                stack.push_back({static_cast<char>(tag), i, style, false});
                style = static_cast<int>(cur->styles.size()) - 1;
            }
            i += 2;
        } else if (c == U'}') {
            if (stack.empty()) err(i, "stray-brace");
            Frame f = stack.back();
            stack.pop_back();
            if (f.footnote) {
                stripGlue(fn);
                (*footnotes)[fnIndex] = std::move(fn);
                fn = InlineText{};
                cur = &main;
                inFootnote = false;
            }
            style = f.savedStyle;
        } else {
            push(Unit::Char, c);
        }
    }
    if (!stack.empty()) err(stack.back().pos, "unclosed-inline");
    stripGlue(main);
    return main;
}

bool isAttrNameChar(char c) {
    return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-';
}
bool isBareChar(char c) { return isAttrNameChar(c) || c == '.' || c == '+' || c == '%'; }

int colOf(std::string_view line, std::size_t byte) { return static_cast<int>(utf8Length(line.substr(0, byte))) + 1; }

enum class Dir { Doc, Toc, Heading, Quote, Group, UList, OList, Li, Table, Hrule, Pre, Fig, Rule, VSpace, NewPage, End };

struct DirSpec {
    Dir dir;
    std::vector<std::string> attrs;
    std::vector<std::string> required;
};

struct Attr {
    std::string name, value;
    int col;
};

class Parser {
public:
    explicit Parser(std::string_view src) {
        std::size_t pos = 0;
        while (pos < src.size()) {
            std::size_t nl = src.find('\n', pos);
            if (nl == std::string_view::npos) nl = src.size();
            lines_.push_back(src.substr(pos, nl - pos));
            pos = nl + 1;
        }
    }

    Document run() {
        for (std::size_t i = 0; i < lines_.size(); ++i) {
            lineNo_ = static_cast<int>(i) + 1;
            handleLine(lines_[i]);
        }
        finalizePending();
        if (!stack_.empty()) fail(static_cast<int>(lines_.size()) + 1, 1, "missing-end");
        return std::move(doc_);
    }

private:
    enum class FK { Doc, Quote, Group, UList, OList, Item, Table, Fig, Pre };
    struct Frame {
        FK kind;
        Block* block = nullptr;
        std::vector<Seg> segs;  // Fig caption
        std::vector<std::string> metaSeen;
    };
    struct Pending {
        bool active = false;
        Block* item = nullptr;  // null: paragraph
        std::vector<Seg> segs;
    };

    std::vector<std::string_view> lines_;
    int lineNo_ = 0;
    Document doc_;
    std::vector<Frame> stack_;
    Pending pending_;
    int topBlocks_ = 0;
    bool tocSeen_ = false;

    std::vector<std::unique_ptr<Block>>& container() {
        return stack_.empty() ? doc_.blocks : stack_.back().block->children;
    }

    Block* addBlock(BlockKind k) {
        auto b = std::make_unique<Block>();
        b->kind = k;
        Block* p = b.get();
        if (stack_.empty()) ++topBlocks_;
        container().push_back(std::move(b));
        return p;
    }

    InlineText scan(const std::vector<Seg>& segs, bool allowFootnote) {
        return scanInline(joinSegs(segs), allowFootnote, allowFootnote ? &doc_.footnotes : nullptr);
    }

    void finalizePending() {
        if (!pending_.active) return;
        Pending p = std::move(pending_);
        pending_ = Pending{};
        InlineText t = scan(p.segs, true);
        if (p.item) {
            p.item->text = std::move(t);
        } else {
            Block* b = addBlock(BlockKind::Paragraph);
            b->text = std::move(t);
        }
    }

    void handleLine(std::string_view line) {
        if (!stack_.empty() && stack_.back().kind == FK::Pre) {
            std::string_view t = trim(line, " ");
            if (t == "@end") {
                stack_.pop_back();
            } else {
                std::size_t e = line.find_last_not_of(' ');
                stack_.back().block->lines.emplace_back(e == std::string_view::npos ? "" : line.substr(0, e + 1));
            }
            return;
        }
        std::size_t f = line.find_first_not_of(' ');
        if (f == std::string_view::npos) {  // blank
            finalizePending();
            return;
        }
        if (line[f] == '@') {
            finalizePending();
            directive(line, f);
        } else {
            text(line, f);
        }
    }

    // ---------------------------------------------------------------- text lines
    void text(std::string_view line, std::size_t f) {
        int col = static_cast<int>(f) + 1;
        if (pending_.active) {
            pending_.segs.push_back({std::string(line.substr(f)), lineNo_, col});
            return;
        }
        if (stack_.empty()) return startParagraph(line, f);
        Frame& top = stack_.back();
        switch (top.kind) {
            case FK::Quote: case FK::Group: case FK::Item:
                startParagraph(line, f);
                break;
            case FK::UList: case FK::OList:
                fail(lineNo_, col, "text-not-allowed");
            case FK::Doc:
                metaLine(line, f);
                break;
            case FK::Table:
                tableRow(line, f);
                break;
            case FK::Fig:
                top.segs.push_back({std::string(line.substr(f)), lineNo_, col});
                break;
            case FK::Pre:
                break;
        }
    }

    void startParagraph(std::string_view line, std::size_t f) {
        pending_.active = true;
        pending_.item = nullptr;
        pending_.segs.clear();
        pending_.segs.push_back({std::string(line.substr(f)), lineNo_, static_cast<int>(f) + 1});
    }

    void metaLine(std::string_view line, std::size_t f) {
        std::size_t k = f;
        while (k < line.size() && ((line[k] >= 'a' && line[k] <= 'z') || (line[k] >= '0' && line[k] <= '9') || line[k] == '-')) ++k;
        std::size_t j = k;
        while (j < line.size() && (line[j] == ' ' || line[j] == '\t')) ++j;
        int col = static_cast<int>(f) + 1;
        if (k == f || j >= line.size() || line[j] != '=') fail(lineNo_, col, "bad-syntax");
        std::string key(line.substr(f, k - f));
        if (key != "title" && key != "author" && key != "date") fail(lineNo_, col, "unknown-meta");
        auto& seen = stack_.back().metaSeen;
        if (std::find(seen.begin(), seen.end(), key) != seen.end()) fail(lineNo_, col, "duplicate-meta");
        seen.push_back(key);
        std::string value(trim(line.substr(j + 1), " \t"));
        if (key == "title") doc_.title = value;
        else if (key == "author") doc_.author = value;
        else doc_.date = value;
    }

    void tableRow(std::string_view line, std::size_t f) {
        Block* tbl = stack_.back().block;
        std::vector<std::pair<std::size_t, std::size_t>> cells;  // byte ranges in `line`
        std::size_t start = f;
        for (std::size_t i = f; i < line.size(); ++i) {
            if (line[i] == '\\') {
                ++i;
            } else if (line[i] == '|') {
                cells.emplace_back(start, i);
                start = i + 1;
            }
        }
        cells.emplace_back(start, line.size());
        if (static_cast<int>(cells.size()) != tbl->cols) fail(lineNo_, 1, "cell-count");
        TableElement el;
        for (auto [b, e] : cells) {
            std::vector<PChar> cs;
            appendChars(cs, Seg{std::string(line.substr(b, e - b)), lineNo_, colOf(line, b)});
            el.cells.push_back(scanInline(cs, false, nullptr));
        }
        tbl->elements.push_back(std::move(el));
    }

    // ---------------------------------------------------------------- directives
    static const DirSpec* lookup(std::string_view name, int& level, bool& star) {
        static const std::vector<std::pair<std::string, DirSpec>> table = {
            {"@doc", {Dir::Doc, {}, {}}},
            {"@toc", {Dir::Toc, {"title"}, {}}},
            {"@q", {Dir::Quote, {}, {}}},
            {"@block", {Dir::Group, {"align", "indent", "right-indent", "font", "size", "leading"}, {}}},
            {"@ul", {Dir::UList, {}, {}}},
            {"@ol", {Dir::OList, {"start"}, {}}},
            {"@li", {Dir::Li, {}, {}}},
            {"@table", {Dir::Table, {"cols", "align"}, {"cols"}}},
            {"@hrule", {Dir::Hrule, {}, {}}},
            {"@pre", {Dir::Pre, {}, {}}},
            {"@fig", {Dir::Fig, {"height", "width"}, {"height"}}},
            {"@rule", {Dir::Rule, {}, {}}},
            {"@vspace", {Dir::VSpace, {"height"}, {"height"}}},
            {"@newpage", {Dir::NewPage, {}, {}}},
            {"@end", {Dir::End, {}, {}}},
        };
        static const DirSpec heading{Dir::Heading, {}, {}};
        level = 0;
        star = false;
        if (name.size() >= 3 && name.size() <= 4 && name[0] == '@' && name[1] == 'h' && name[2] >= '1' && name[2] <= '4') {
            if (name.size() == 3 || name[3] == '*') {
                level = name[2] - '0';
                star = name.size() == 4;
                return &heading;
            }
            return nullptr;
        }
        for (const auto& [n, spec] : table)
            if (name == n) return &spec;
        return nullptr;
    }

    void directive(std::string_view line, std::size_t at) {
        int atCol = static_cast<int>(at) + 1;
        std::size_t nameEnd = line.find(' ', at);
        if (nameEnd == std::string_view::npos) nameEnd = line.size();
        std::string_view name = line.substr(at, nameEnd - at);
        int level;
        bool star;
        const DirSpec* spec = lookup(name, level, star);
        if (!spec) fail(lineNo_, atCol, "unknown-block");
        Dir dir = spec->dir;

        // 1. attributes (headings and @li take inline text instead)
        std::vector<Attr> attrs;
        if (dir != Dir::Heading && dir != Dir::Li) attrs = readAttrs(line, nameEnd, *spec);
        // 2. required attributes
        for (const auto& req : spec->required) {
            bool found = false;
            for (const auto& a : attrs) found = found || a.name == req;
            if (!found) fail(lineNo_, atCol, "missing-attribute");
        }
        // 3. placement
        checkPlacement(dir, atCol);
        // 4/5. values, then the block itself
        switch (dir) {
            case Dir::Doc:
                ++topBlocks_;
                doc_.hasDoc = true;
                stack_.push_back({FK::Doc, nullptr, {}, {}});
                break;
            case Dir::Toc:
                ++topBlocks_;
                tocSeen_ = true;
                doc_.hasToc = true;
                for (const auto& a : attrs)
                    if (a.name == "title") doc_.tocTitle = a.value;
                break;
            case Dir::Heading: heading(line, nameEnd, level, star); break;
            case Dir::Quote: openContainer(BlockKind::Quote, FK::Quote); break;
            case Dir::Group: {
                Block tmp;
                for (const auto& a : attrs) {
                    if (a.name == "align") tmp.align = alignAttr(a);
                    else if (a.name == "font") tmp.font = fontAttr(a);
                    else if (a.name == "indent") tmp.indent = lengthAttr(a, 0, kBig);
                    else if (a.name == "right-indent") tmp.rightIndent = lengthAttr(a, 0, kBig);
                    else if (a.name == "size") tmp.size = lengthAttr(a, 1000, 200000);
                    else if (a.name == "leading") tmp.leading = lengthAttr(a, 1000, kBig);
                }
                Block* b = openContainer(BlockKind::Group, FK::Group);
                b->align = tmp.align;
                b->font = tmp.font;
                b->indent = tmp.indent;
                b->rightIndent = tmp.rightIndent;
                b->size = tmp.size;
                b->leading = tmp.leading;
                break;
            }
            case Dir::UList: openContainer(BlockKind::UList, FK::UList); break;
            case Dir::OList: {
                i64 start = 1;
                for (const auto& a : attrs) start = intAttr(a, 1, 100000);
                Block* b = openContainer(BlockKind::OList, FK::OList);
                b->start = start;
                break;
            }
            case Dir::Li: listItem(line, nameEnd); break;
            case Dir::Table: {
                int cols = 0;
                const Attr* alignAttrPtr = nullptr;
                for (const auto& a : attrs) {
                    if (a.name == "cols") cols = static_cast<int>(intAttr(a, 1, 20));
                    else {
                        alignAttrPtr = &a;
                        for (char ch : a.value)
                            if (ch != 'l' && ch != 'r' && ch != 'c') fail(lineNo_, a.col, "bad-attribute-value");
                    }
                }
                std::string colAlign = alignAttrPtr ? alignAttrPtr->value : std::string(cols, 'l');
                if (static_cast<int>(colAlign.size()) != cols) fail(lineNo_, alignAttrPtr->col, "bad-attribute-value");
                Block* b = openContainer(BlockKind::Table, FK::Table);
                b->cols = cols;
                b->colAlign = colAlign;
                break;
            }
            case Dir::Hrule: {
                TableElement el;
                el.hrule = true;
                stack_.back().block->elements.push_back(std::move(el));
                break;
            }
            case Dir::Pre: {
                Block* b = addBlock(BlockKind::Pre);
                stack_.push_back({FK::Pre, b, {}, {}});
                break;
            }
            case Dir::Fig: {
                i64 height = 0;
                std::optional<i64> width;
                for (const auto& a : attrs) {
                    if (a.name == "height") height = lengthAttr(a, 0, kBig);
                    else width = lengthAttr(a, 0, kBig);
                }
                Block* b = openContainer(BlockKind::Figure, FK::Fig);
                b->height = height;
                b->width = width;
                break;
            }
            case Dir::Rule: addBlock(BlockKind::Rule); break;
            case Dir::VSpace: {
                i64 h = lengthAttr(attrs[0], 0, kBig);
                Block* b = addBlock(BlockKind::VSpace);
                b->height = h;
                break;
            }
            case Dir::NewPage: addBlock(BlockKind::NewPage); break;
            case Dir::End: endBlock(); break;
        }
    }

    static constexpr i64 kBig = 4000000000000000000LL;

    i64 lengthAttr(const Attr& a, i64 lo, i64 hi) {
        auto v = parseLength(a.value);
        if (!v || *v < lo || *v > hi) fail(lineNo_, a.col, "bad-attribute-value");
        return *v;
    }
    i64 intAttr(const Attr& a, i64 lo, i64 hi) {
        auto v = parseInteger(a.value);
        if (!v || *v < lo || *v > hi) fail(lineNo_, a.col, "bad-attribute-value");
        return *v;
    }
    Align alignAttr(const Attr& a) {
        if (a.value == "justify") return Align::Justify;
        if (a.value == "left") return Align::Left;
        if (a.value == "right") return Align::Right;
        if (a.value == "center") return Align::Center;
        fail(lineNo_, a.col, "bad-attribute-value");
    }
    Family fontAttr(const Attr& a) {
        if (a.value == "serif") return Family::Serif;
        if (a.value == "sans") return Family::Sans;
        if (a.value == "mono") return Family::Mono;
        fail(lineNo_, a.col, "bad-attribute-value");
    }

    std::vector<Attr> readAttrs(std::string_view line, std::size_t p, const DirSpec& spec) {
        std::vector<Attr> out;
        while (true) {
            while (p < line.size() && line[p] == ' ') ++p;
            if (p >= line.size()) break;
            std::size_t tokenStart = p, nameStart = p;
            while (p < line.size() && isAttrNameChar(line[p])) ++p;
            if (p == nameStart || p >= line.size() || line[p] != '=') fail(lineNo_, colOf(line, tokenStart), "bad-attribute");
            std::string name(line.substr(nameStart, p - nameStart));
            bool known = std::find(spec.attrs.begin(), spec.attrs.end(), name) != spec.attrs.end();
            bool dup = false;
            for (const auto& a : out) dup = dup || a.name == name;
            if (!known || dup) fail(lineNo_, colOf(line, nameStart), "bad-attribute");
            ++p;
            std::size_t valueStart = p;
            int valueCol = colOf(line, valueStart);
            std::string value;
            if (p < line.size() && line[p] == '"') {
                std::size_t q = line.find('"', p + 1);
                if (q == std::string_view::npos) fail(lineNo_, valueCol, "bad-attribute-value");
                value = std::string(line.substr(p + 1, q - p - 1));
                p = q + 1;
            } else {
                std::size_t b = p;
                while (p < line.size() && isBareChar(line[p])) ++p;
                if (p == b) fail(lineNo_, valueCol, "bad-attribute-value");
                value = std::string(line.substr(b, p - b));
            }
            if (p < line.size() && line[p] != ' ') fail(lineNo_, valueCol, "bad-attribute-value");
            out.push_back({name, value, valueCol});
        }
        return out;
    }

    void checkPlacement(Dir dir, int atCol) {
        auto notAllowed = [&] { fail(lineNo_, atCol, "block-not-allowed"); };
        FK top = stack_.empty() ? FK::Quote : stack_.back().kind;  // Quote stands for "top level"
        bool atTop = stack_.empty();
        bool admitsBlocks = atTop || top == FK::Quote || top == FK::Group || top == FK::Item;
        switch (dir) {
            case Dir::End:
                if (atTop) fail(lineNo_, atCol, "unexpected-end");
                return;
            case Dir::Li:
                if (atTop || (top != FK::UList && top != FK::OList && top != FK::Item)) notAllowed();
                return;
            case Dir::Hrule:
                if (atTop || top != FK::Table) notAllowed();
                return;
            case Dir::Doc:
                if (!atTop || topBlocks_ != 0) notAllowed();
                return;
            case Dir::Toc:
                if (tocSeen_) {
                    if (!admitsBlocks) notAllowed();
                    fail(lineNo_, atCol, "duplicate-toc");
                }
                if (!atTop || !(topBlocks_ == 0 || (topBlocks_ == 1 && doc_.hasDoc))) notAllowed();
                return;
            default:
                if (!admitsBlocks) notAllowed();
                return;
        }
    }

    Block* openContainer(BlockKind kind, FK fk) {
        Block* b = addBlock(kind);
        stack_.push_back({fk, b, {}, {}});
        return b;
    }

    void heading(std::string_view line, std::size_t nameEnd, int level, bool star) {
        std::size_t f = line.find_first_not_of(' ', nameEnd);
        std::vector<Seg> segs;
        if (f != std::string_view::npos) segs.push_back({std::string(line.substr(f)), lineNo_, colOf(line, f)});
        InlineText t = scanInline(joinSegs(segs), false, nullptr);
        Block* b = addBlock(BlockKind::Heading);
        b->level = level;
        b->numbered = !star;
        b->plain = plainText(t);
        b->text = std::move(t);
    }

    void listItem(std::string_view line, std::size_t nameEnd) {
        if (stack_.back().kind == FK::Item) stack_.pop_back();
        Block* list = stack_.back().block;
        auto item = std::make_unique<Block>();
        item->kind = BlockKind::Item;
        Block* it = item.get();
        list->children.push_back(std::move(item));
        stack_.push_back({FK::Item, it, {}, {}});
        pending_.active = true;
        pending_.item = it;
        pending_.segs.clear();
        std::size_t f = line.find_first_not_of(' ', nameEnd);
        if (f != std::string_view::npos) pending_.segs.push_back({std::string(line.substr(f)), lineNo_, colOf(line, f)});
    }

    void endBlock() {
        if (stack_.back().kind == FK::Item) stack_.pop_back();
        Frame f = std::move(stack_.back());
        stack_.pop_back();
        if (f.kind == FK::Fig) f.block->text = scan(f.segs, false);
    }

};

}  // namespace

Document Document::parse(std::string_view source) { return Parser(source).run(); }

std::string plainText(const InlineText& t) {
    std::string raw;
    for (const Unit& u : t.units) {
        switch (u.kind) {
            case Unit::Char: appendUtf8(raw, u.c); break;
            case Unit::Glue: case Unit::RigidSpace: raw += ' '; break;
            default: break;
        }
    }
    std::string out;
    for (char c : raw)
        if (!(c == ' ' && !out.empty() && out.back() == ' ')) out += c;
    return std::string(trim(out, " "));
}

std::vector<Unit> plainUnits(std::string_view utf8, bool dropEdgeGlue) {
    InlineText t;
    for (char32_t c : utf8ToU32(utf8)) {
        Unit u;
        if (c == U' ') {
            if (t.units.empty() || t.units.back().kind == Unit::Glue) {
                if (t.units.empty() && !dropEdgeGlue) { u.kind = Unit::Glue; t.units.push_back(u); }
                continue;
            }
            u.kind = Unit::Glue;
        } else {
            u.kind = Unit::Char;
            u.c = c;
        }
        t.units.push_back(u);
    }
    if (dropEdgeGlue) stripGlue(t);
    return std::move(t.units);
}

}  // namespace typeset
