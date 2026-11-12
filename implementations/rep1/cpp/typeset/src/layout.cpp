#include "typeset/layout.hpp"

#include <algorithm>

namespace typeset {

namespace {

Unit charUnit(char32_t c) {
    Unit u;
    u.kind = Unit::Char;
    u.c = c;
    return u;
}

void appendString(std::vector<Unit>& units, std::string_view utf8) {
    for (char32_t c : utf8ToU32(utf8)) units.push_back(charUnit(c));
}

Unit rigidFixed(i64 w) {
    Unit u;
    u.kind = Unit::RigidFixed;
    u.width = w;
    return u;
}

}  // namespace

// ------------------------------------------------------------------ helpers

Context Layouter::rootContext() const {
    Context c;
    c.family = s_.bodyFont;
    c.bold = c.italic = false;
    c.size = s_.bodySize;
    c.leading = s_.leading;
    c.left = s_.bodyX();
    c.measure = s_.bodyWidth();
    c.align = s_.align;
    c.hyphenate = s_.hyphenate;
    return c;
}

void Layouter::pushGlue(i64 h) {
    VItem g;
    g.kind = VItem::Glue;
    g.height = h;
    out_->items.push_back(g);
}

template <class F>
void Layouter::leaf(i64 before, i64 after, F&& emit) {
    reg_.pendingMax = std::max(reg_.pendingMax, before);
    if (reg_.started && reg_.pendingMax + reg_.pendingAdd > 0) pushGlue(reg_.pendingMax + reg_.pendingAdd);
    reg_.pendingMax = after;
    reg_.pendingAdd = 0;
    emit();
    reg_.started = true;
}

int Layouter::addLine(PlacedLine line) {
    out_->lines.push_back(std::move(line));
    return static_cast<int>(out_->lines.size()) - 1;
}

void Layouter::pushGroup(std::vector<PlacedLine> lines, bool heading, int headingId, i64 leading) {
    int group = nextGroup_++;
    int n = static_cast<int>(lines.size());
    for (int k = 1; k <= n; ++k) {
        VItem it;
        it.kind = VItem::Line;
        it.index = addLine(std::move(lines[k - 1]));
        it.group = group;
        it.k = k;
        it.n = n;
        it.heading = heading;
        it.headingId = (k == 1) ? headingId : -1;
        it.leading = leading;
        out_->items.push_back(it);
    }
}

void Layouter::forceBreak() {
    VItem f;
    f.kind = VItem::ForceBreak;
    out_->items.push_back(f);
    reg_.pendingMax = reg_.pendingAdd = 0;
}

// --------------------------------------------------------------- body walk

BodyLayout Layouter::layoutBody(const Document& doc) {
    BodyLayout body;
    body_ = &body;
    out_ = &body.list;
    resetRegisters();
    nextGroup_ = 1;
    for (int& c : counters_) c = 0;

    // Footnotes: each is broken once, up front.
    stats_.footnotes = static_cast<i64>(doc.footnotes.size());
    Context fc;
    fc.family = s_.footnoteFont;
    fc.size = s_.footnoteSize;
    fc.leading = s_.footnoteLeading;
    fc.left = s_.bodyX() + s_.footnoteIndent;
    fc.measure = clampMeasure(s_.bodyWidth() - s_.footnoteIndent);
    fc.align = s_.align;
    fc.hyphenate = s_.hyphenate;
    for (const InlineText& fn : doc.footnotes) {
        HList h = builder_.build(fn, fc);
        body.footnoteLines.push_back(typesetList(h, s_, fonts_, stats_));
    }

    walk(doc.blocks, rootContext(), 0);
    body_ = nullptr;
    out_ = nullptr;
    return body;
}

void Layouter::walk(const std::vector<std::unique_ptr<Block>>& blocks, const Context& ctx, int depth) {
    for (const auto& b : blocks) walkBlock(*b, ctx, depth);
}

void Layouter::walkBlock(const Block& b, const Context& ctx, int depth) {
    switch (b.kind) {
        case BlockKind::Paragraph:
            ++stats_.paragraphs;
            leaf(s_.parSpace, s_.parSpace, [&] {
                Context c = ctx;
                c.firstIndent = s_.parIndent;
                HList h = builder_.build(b.text, c);
                pushGroup(typesetList(h, s_, fonts_, stats_), false, -1, ctx.leading);
            });
            break;
        case BlockKind::Heading: walkHeading(b, ctx); break;
        case BlockKind::Quote: {
            reg_.pendingMax = std::max(reg_.pendingMax, s_.quoteSpace);
            Context c = ctx;
            c.left += s_.quoteIndent;
            c.measure = clampMeasure(ctx.measure - 2 * s_.quoteIndent);
            walk(b.children, c, depth);
            reg_.pendingMax = std::max(reg_.pendingMax, s_.quoteSpace);
            break;
        }
        case BlockKind::Group: {
            Context c = ctx;
            if (b.align) c.align = *b.align;
            if (b.size) c.size = *b.size;
            if (b.leading) c.leading = *b.leading;
            if (b.font) c.family = *b.font;
            i64 ind = b.indent.value_or(0), rind = b.rightIndent.value_or(0);
            c.left += ind;
            c.measure = clampMeasure(ctx.measure - ind - rind);
            walk(b.children, c, depth);
            break;
        }
        case BlockKind::UList:
        case BlockKind::OList: walkList(b, ctx, depth); break;
        case BlockKind::Item: break;  // handled by walkList
        case BlockKind::Table: walkTable(b, ctx); break;
        case BlockKind::Pre: walkPre(b, ctx); break;
        case BlockKind::Figure: walkFigure(b); break;
        case BlockKind::Rule:
            leaf(s_.ruleSpace, s_.ruleSpace, [&] {
                VItem r;
                r.kind = VItem::Rule;
                r.x = ctx.left;
                r.width = ctx.measure;
                r.height = s_.ruleThickness;
                out_->items.push_back(r);
            });
            break;
        case BlockKind::VSpace: reg_.pendingAdd += b.height; break;
        case BlockKind::NewPage: forceBreak(); break;
    }
}

void Layouter::walkList(const Block& b, const Context& ctx, int depth) {
    const bool ordered = b.kind == BlockKind::OList;
    const int d = depth + 1;
    reg_.pendingMax = std::max(reg_.pendingMax, s_.listSpace);
    Context c = ctx;
    c.left += s_.listIndent;
    c.measure = clampMeasure(ctx.measure - s_.listIndent);

    i64 idx = 0;
    for (const auto& itemPtr : b.children) {
        const Block& item = *itemPtr;
        if (idx > 0) reg_.pendingMax = std::max(reg_.pendingMax, s_.listItemSpace);
        i64 number = (ordered ? b.start : 1) + idx;
        std::string marker;
        switch (d % 3) {
            case 1: marker = ordered ? std::to_string(number) + "." : "\xE2\x80\xA2"; break;
            case 2: marker = ordered ? toLetters(number) + "." : "\xE2\x80\x93"; break;
            default: marker = ordered ? toRoman(number) + "." : "*"; break;
        }
        leaf(0, 0, [&] {
            HList h = builder_.build(item.text, c);
            std::vector<PlacedLine> lines = typesetList(h, s_, fonts_, stats_);
            int face = faceIndex(c.family, false, false);
            Run m;
            m.face = face;
            m.size = c.size;
            m.text = marker;
            m.width = fonts_.face(face).width(utf8ToU32(marker), c.size);
            m.x = c.left - s_.listMarkerGap - m.width;
            lines[0].extras.push_back(std::move(m));
            pushGroup(std::move(lines), false, -1, c.leading);
        });
        walk(item.children, c, d);
        ++idx;
    }
    reg_.pendingMax = std::max(reg_.pendingMax, s_.listSpace);
}

void Layouter::walkHeading(const Block& b, const Context& ctx) {
    ++stats_.headings;
    const int level = b.level;
    const bool numbered = b.numbered && s_.headingNumber;
    std::string number;
    if (numbered) {
        ++counters_[level - 1];
        for (int m = level; m < 4; ++m) counters_[m] = 0;
        number = std::to_string(counters_[0]);
        for (int m = 1; m < level; ++m) number += "." + std::to_string(counters_[m]);
    }
    HeadingInfo info;
    info.level = level;
    info.number = number;
    info.plain = b.plain;
    info.inToc = b.numbered && level <= s_.tocDepth;
    int hid = static_cast<int>(body_->headings.size());
    body_->headings.push_back(info);

    if (level == 1 && s_.h1Newpage) forceBreak();
    leaf(s_.hSpaceBefore[level - 1], s_.hSpaceAfter[level - 1], [&] {
        Context c = ctx;
        c.family = s_.headingFont;
        c.bold = s_.headingBold;
        c.italic = s_.headingItalic;
        c.size = s_.hSize[level - 1];
        c.leading = s_.hLeading[level - 1];
        c.align = s_.headingAlign;
        c.firstIndent = 0;
        std::vector<Unit> units;
        if (numbered) {
            appendString(units, number);
            units.push_back(rigidFixed(s_.headingNumberGap));
        }
        units.insert(units.end(), b.text.units.begin(), b.text.units.end());
        HList h = builder_.build(units, b.text.styles, c);
        pushGroup(typesetList(h, s_, fonts_, stats_), true, hid, c.leading);
    });
}

void Layouter::walkPre(const Block& b, const Context& ctx) {
    leaf(s_.preSpace, s_.preSpace, [&] {
        Context c = ctx;
        c.family = s_.preFont;
        c.bold = c.italic = false;
        c.size = s_.preSize;
        c.leading = s_.preLeading;
        c.align = Align::Left;
        c.left = ctx.left + s_.preIndent;
        c.measure = clampMeasure(ctx.measure - s_.preIndent);
        c.firstIndent = 0;
        std::vector<PlacedLine> all;
        for (const std::string& text : b.lines) {
            HList h = builder_.buildVerbatim(text, c);
            auto lines = setLines(h, {h.finalIndex()}, fonts_, stats_);
            all.push_back(std::move(lines[0]));
        }
        // One group of n lines: every line is its own list, but widow/orphan
        // rules see them as a single group.
        pushGroup(std::move(all), false, -1, c.leading);
    });
}

void Layouter::walkTable(const Block& b, const Context& ctx) {
    ++stats_.tables;
    leaf(s_.tableSpace, s_.tableSpace, [&] {
        const int cols = b.cols;
        struct Cell {
            HList list;
        };
        std::vector<std::vector<Cell>> rows;  // one entry per table element (empty for hrules)
        std::vector<i64> nat(cols, 0), mn(cols, 0);
        for (const TableElement& el : b.elements) {
            std::vector<Cell> cells;
            if (!el.hrule) {
                for (int i = 0; i < cols; ++i) {
                    Context c = ctx;
                    c.bold = c.italic = false;
                    c.leading = s_.tableLeading;
                    c.firstIndent = 0;
                    char letter = b.colAlign[i];
                    c.align = letter == 'r' ? Align::Right : letter == 'c' ? Align::Center : Align::Left;
                    HList h = builder_.build(el.cells[i], c);
                    nat[i] = std::max(nat[i], h.naturalWidth());
                    mn[i] = std::max(mn[i], h.minWidth());
                    cells.push_back({std::move(h)});
                }
            }
            rows.push_back(std::move(cells));
        }

        // Column widths
        i64 A = std::max<i64>(0, ctx.measure - (cols - 1) * s_.tableColGap);
        i64 sumNat = 0, sumMin = 0;
        for (int i = 0; i < cols; ++i) { sumNat += nat[i]; sumMin += mn[i]; }
        std::vector<i64> w(cols);
        if (sumNat <= A) {
            w = nat;
        } else if (sumMin >= A) {
            w = mn;
        } else {
            i64 D = sumNat - A, S = sumNat - sumMin, P = 0, prevC = 0;
            for (int i = 0; i < cols; ++i) {
                P += nat[i] - mn[i];
                i64 C = static_cast<i64>(static_cast<__int128>(D) * P / S);
                w[i] = nat[i] - (C - prevC);
                prevC = C;
            }
        }
        i64 TW = (cols - 1) * s_.tableColGap;
        for (i64 x : w) TW += x;
        std::vector<i64> colX(cols);
        i64 x = ctx.left;
        for (int i = 0; i < cols; ++i) {
            colX[i] = x;
            x += w[i] + s_.tableColGap;
        }

        bool prevRow = false;
        const std::size_t count = b.elements.size();
        for (std::size_t e = 0; e < count; ++e) {
            if (!b.elements[e].hrule) {
                if (prevRow) pushGlue(s_.tableRowSpace);
                std::vector<std::vector<PlacedLine>> cellLines(cols);
                i64 Arow = 0, Drow = 0;
                std::size_t nrow = 0;
                for (int i = 0; i < cols; ++i) {
                    HList& h = rows[e][i].list;
                    h.context.left = colX[i];
                    h.context.measure = std::max<i64>(w[i], 1);
                    cellLines[i] = typesetList(h, s_, fonts_, stats_);
                    Arow = std::max(Arow, cellLines[i].front().ascent);
                    Drow = std::max(Drow, cellLines[i].back().depth);
                    nrow = std::max(nrow, cellLines[i].size());
                }
                Row row;
                row.height = Arow + static_cast<i64>(nrow - 1) * s_.tableLeading + Drow;
                for (int i = 0; i < cols; ++i)
                    for (std::size_t k = 0; k < cellLines[i].size(); ++k)
                        row.lines.push_back({std::move(cellLines[i][k]), Arow + static_cast<i64>(k) * s_.tableLeading});
                out_->rows.push_back(std::move(row));
                VItem it;
                it.kind = VItem::RowItem;
                it.index = static_cast<int>(out_->rows.size()) - 1;
                it.height = out_->rows.back().height;
                out_->items.push_back(it);
                prevRow = true;
            } else {
                if (e != 0) pushGlue(s_.tableRuleSpace);
                VItem r;
                r.kind = VItem::Rule;
                r.x = ctx.left;
                r.width = TW;
                r.height = s_.tableRuleThickness;
                out_->items.push_back(r);
                if (e + 1 != count) pushGlue(s_.tableRuleSpace);
                prevRow = false;
            }
        }
    });
}

void Layouter::walkFigure(const Block& b) {
    ++stats_.figures;
    const int number = static_cast<int>(body_->figures.size()) + 1;
    FigureBlock fig;
    i64 W = b.width.value_or(s_.figureWidth);
    i64 fw = W > 0 ? W : s_.bodyWidth();
    i64 fx = s_.bodyX() + floorDiv(s_.bodyWidth() - fw, 2);
    fig.frame = s_.figureFrame;
    fig.frameHeight = b.height;
    fig.x = fx;
    fig.width = fw;

    std::vector<Unit> units;
    if (!s_.figureCaptionPrefix.empty()) {
        units = plainUnits(s_.figureCaptionPrefix);
        Unit g;
        g.kind = Unit::Glue;
        g.plainGlue = true;
        units.push_back(g);
    }
    appendString(units, std::to_string(number) + ".");
    units.push_back(rigidFixed(s_.figureCaptionGap));
    units.insert(units.end(), b.text.units.begin(), b.text.units.end());

    Context c;
    c.family = s_.figureCaptionFont;
    c.size = s_.figureCaptionSize;
    c.leading = s_.figureCaptionLeading;
    c.left = fx;
    c.measure = clampMeasure(fw);
    c.align = s_.figureCaptionAlign;
    c.hyphenate = s_.hyphenate;
    HList h = builder_.build(units, b.text.styles, c);
    std::vector<PlacedLine> lines = typesetList(h, s_, fonts_, stats_);

    i64 baseline = 0, prevBaseline = 0, prevDepth = 0;
    for (std::size_t k = 0; k < lines.size(); ++k) {
        if (k == 0) baseline = b.height + s_.figureCaptionSpace + lines[k].ascent;
        else baseline = prevBaseline + std::max(c.leading, prevDepth + s_.lineSkip + lines[k].ascent);
        prevBaseline = baseline;
        prevDepth = lines[k].depth;
        fig.caption.push_back({std::move(lines[k]), baseline});
    }
    fig.height = prevBaseline + prevDepth;
    body_->figures.push_back(std::move(fig));

    leaf(0, 0, [&] {
        VItem m;
        m.kind = VItem::FloatMark;
        m.index = number - 1;
        out_->items.push_back(m);
    });
}

// --------------------------------------------------------------------- TOC

VList Layouter::layoutToc(const std::string& title, const std::vector<TocEntry>& entries) {
    VList vl;
    out_ = &vl;
    body_ = nullptr;
    resetRegisters();
    nextGroup_ = 1;

    {
        Context c;
        c.family = s_.tocTitleFont;
        c.bold = s_.headingBold;
        c.italic = s_.headingItalic;
        c.size = s_.tocTitleSize;
        c.leading = s_.hLeading[0];
        c.left = s_.bodyX();
        c.measure = s_.bodyWidth();
        c.align = s_.headingAlign;
        c.hyphenate = s_.hyphenate;
        leaf(0, s_.tocTitleSpaceAfter, [&] {
            HList h = builder_.build(plainUnits(title), std::vector<StyleNode>{StyleNode{}}, c);
            pushGroup(typesetList(h, s_, fonts_, stats_), false, -1, c.leading);
        });
    }

    const int face = faceIndex(s_.tocFont, false, false);
    const Face& f = fonts_.face(face);
    for (const TocEntry& e : entries) {
        Context c;
        c.family = s_.tocFont;
        c.size = s_.tocSize;
        c.leading = s_.tocLeading;
        c.left = s_.bodyX() + (e.level - 1) * s_.tocIndent;
        c.measure = clampMeasure(s_.bodyWidth() - (e.level - 1) * s_.tocIndent - s_.tocReserve);
        c.align = Align::Left;
        c.hyphenate = s_.hyphenate;
        leaf(s_.tocEntrySpace, s_.tocEntrySpace, [&] {
            std::vector<Unit> units;
            if (!e.number.empty()) {
                appendString(units, e.number);
                units.push_back(rigidFixed(s_.tocNumberGap));
            }
            std::vector<Unit> text = plainUnits(e.plain);
            units.insert(units.end(), text.begin(), text.end());
            HList h = builder_.build(units, std::vector<StyleNode>{StyleNode{}}, c);
            std::vector<PlacedLine> lines = typesetList(h, s_, fonts_, stats_);

            PlacedLine& last = lines.back();
            Run label;
            label.face = face;
            label.size = s_.tocSize;
            label.text = e.pageLabel;
            label.width = f.width(utf8ToU32(e.pageLabel), s_.tocSize);
            label.x = s_.bodyX() + s_.bodyWidth() - label.width;
            i64 xFrom = last.endX + s_.tocLeaderGap;
            i64 xTo = label.x - s_.tocLeaderGap;
            i64 unit = f.width(utf8ToU32(s_.tocLeader), s_.tocSize);
            i64 k = unit > 0 ? std::max<i64>(0, floorDiv(xTo - xFrom, unit)) : 0;
            if (k > 0) {
                Run leader;
                leader.face = face;
                leader.size = s_.tocSize;
                leader.width = k * unit;
                leader.x = xTo - k * unit;
                for (i64 i = 0; i < k; ++i) leader.text += s_.tocLeader;
                last.extras.push_back(std::move(leader));
            }
            last.extras.push_back(std::move(label));
            pushGroup(std::move(lines), false, -1, c.leading);
        });
    }
    out_ = nullptr;
    return vl;
}

}  // namespace typeset
