#include "typeset/paginate.hpp"

#include <algorithm>
#include <deque>

namespace typeset {

namespace {

/// The vertical placement rule of "Vertical placement on a page".
struct Flow {
    i64 cursor = 0;
    i64 prevBaseline = 0, prevDepth = 0;
    bool fresh = true;

    i64 line(i64 ascent, i64 depth, i64 leading, i64 lineSkip) {
        i64 baseline = fresh ? cursor + ascent : prevBaseline + std::max(leading, prevDepth + lineSkip + ascent);
        cursor = baseline + depth;
        prevBaseline = baseline;
        prevDepth = depth;
        fresh = false;
        return baseline;
    }
};

/// A footnote (or the unplaced tail of one): a slice of its lines.
struct FnGroup {
    int number;
    const std::vector<PlacedLine>* lines;
    std::size_t from, to;  ///< the slice [from, to) of the footnote's lines
    bool mark;             ///< whether the footnote's number mark is drawn with its first line
    std::size_t size() const { return to - from; }
};

struct FootnotePlan {
    std::vector<FnGroup> placed;  ///< groups (or heads of groups) placed on this page
    std::vector<FnGroup> rest;    ///< carried to the next page
};

/// Step 5 of page breaking: how many footnote lines fit, and how they split.
FootnotePlan planFootnotes(const Settings& s, const std::vector<FnGroup>& cand, i64 avail, bool bodyEmpty) {
    std::size_t total = 0;
    for (const FnGroup& g : cand) total += g.size();
    std::size_t prefix = 0, lastGroup = 0, placedInLast = 0;
    {
        Flow fl;
        bool stop = false, firstGroup = true;
        for (std::size_t g = 0; g < cand.size() && !stop; ++g) {
            Flow t = fl;
            if (!firstGroup) {
                t.cursor += s.footnoteItemSpace;
                t.fresh = true;
            }
            std::size_t placed = 0;
            for (std::size_t k = cand[g].from; k < cand[g].to; ++k) {
                Flow t2 = t;
                const PlacedLine& l = (*cand[g].lines)[k];
                t2.line(l.ascent, l.depth, s.footnoteLeading, s.lineSkip);
                if (t2.cursor > avail) { stop = true; break; }
                t = t2;
                ++placed;
            }
            if (placed > 0) {
                prefix += placed;
                lastGroup = g;
                placedInLast = placed;
                fl = t;
                firstGroup = false;
            }
        }
    }
    if (prefix > 0 && placedInLast < cand[lastGroup].size() && static_cast<i64>(placedInLast) < s.footnoteMinSplit &&
        prefix > placedInLast)
        prefix -= placedInLast;
    if (bodyEmpty && prefix == 0 && total > 0) prefix = 1;

    FootnotePlan plan;
    std::size_t left = prefix;
    for (const FnGroup& g : cand) {
        if (left >= g.size() && left > 0) {
            plan.placed.push_back(g);
            left -= g.size();
        } else if (left > 0) {
            FnGroup head = g, tail = g;
            head.to = g.from + left;
            tail.from = g.from + left;
            tail.mark = false;
            plan.placed.push_back(head);
            plan.rest.push_back(tail);
            left = 0;
        } else {
            plan.rest.push_back(g);
        }
    }
    return plan;
}

/// Height of a stack of footnote groups, built incrementally.
struct FnStack {
    const Settings& s;
    Flow flow;
    bool any = false, firstGroup = true;
    explicit FnStack(const Settings& st) : s(st) {}
    void startGroup() {
        if (!firstGroup) {
            flow.cursor += s.footnoteItemSpace;
            flow.fresh = true;
        }
        firstGroup = false;
    }
    void addLine(const PlacedLine& l) {
        flow.line(l.ascent, l.depth, s.footnoteLeading, s.lineSkip);
        any = true;
    }
    i64 area() const {
        return any ? s.footnoteSpaceBefore + s.footnoteRuleThickness + s.footnoteSpaceAfter + flow.cursor : 0;
    }
};

OutItem textItem(Region r, const Run& run, i64 baseline) {
    OutItem o;
    o.kind = OutItem::Text;
    o.region = r;
    o.face = run.face;
    o.size = run.size;
    o.x = run.x;
    o.y = baseline - run.raise;
    o.width = run.width;
    o.text = run.text;
    return o;
}

void emitLine(std::vector<OutItem>& out, Region r, const PlacedLine& line, i64 baseline, Stats& stats) {
    ++stats.lines;
    for (const Run& run : line.runs) out.push_back(textItem(r, run, baseline));
    for (const Run& run : line.extras) out.push_back(textItem(r, run, baseline));
}

std::vector<char> legalBreaks(const Settings& s, const std::vector<VItem>& items) {
    const std::size_t n = items.size();
    std::vector<char> legal(n + 1, 1);
    legal[0] = 0;
    std::vector<char> keep(n + 1, 0);
    for (std::size_t j = 0; j < n; ++j) {
        const VItem& it = items[j];
        if (it.kind != VItem::Line) continue;
        if (it.heading) {
            if (it.k != 1) legal[j] = 0;
        } else if (it.k > 1) {
            if (!(it.k - 1 >= s.orphans && it.n - it.k + 1 >= s.widows)) legal[j] = 0;
        }
        if (s.keepWithNext && it.heading && it.k == 1) {
            std::size_t last = j + it.n - 1;
            for (std::size_t p = j + 1; p <= last && p < n; ++p) keep[p] = 1;
            std::size_t p = last + 1;
            while (p < n && (items[p].kind == VItem::Glue || items[p].kind == VItem::FloatMark)) keep[p++] = 1;
            if (p < n) keep[p] = 1;
        }
    }
    for (std::size_t j = 0; j < n; ++j)
        if (keep[j]) legal[j] = 0;
    legal[n] = n > 0;
    return legal;
}

}  // namespace

std::vector<PageRecord> paginate(const Settings& s, const FontSet& fonts, Stats& stats, const PaginateInput& in) {
        const std::vector<VItem>& items = in.list.items;
    const int n = static_cast<int>(items.size());
    const std::vector<char> legal = legalBreaks(s, items);
    const i64 bodyHeight = s.bodyHeight();
    const bool haveFootnotes = in.footnotes != nullptr;

    std::vector<PageRecord> pages;
    std::deque<int> queue;
    std::vector<FnGroup> carried;
    int i = 0;
    int chapter = -1, section = -1;
    int pageNo = 0;

    while (true) {
        while (i < n && (items[i].kind == VItem::Glue || items[i].kind == VItem::ForceBreak)) ++i;
        if (i == n && queue.empty() && carried.empty()) break;
        ++pageNo;
        PageRecord page;

        // 1. figures for the float zone
        std::vector<int> taken;
        i64 zone = 0;
        const bool bodyLeft = i < n;
        while (!queue.empty()) {
            const FigureBlock& fig = (*in.figures)[queue.front()];
            i64 z1 = zone + fig.height + s.floatSpaceAfter;
            bool ok = bodyLeft ? (bodyHeight - z1 >= s.floatMinBody) : (taken.empty() || z1 <= bodyHeight);
            if (!ok) break;
            taken.push_back(queue.front());
            queue.pop_front();
            zone = z1;
        }
        const i64 bodyTop = s.bodyY() + zone;
        const i64 goal = bodyHeight - zone;

        // 2./3. choose the cut
        int cut = n;
        if (i < n) {
            FnStack stack(s);
            for (const FnGroup& g : carried) {
                stack.startGroup();
                for (std::size_t k = g.from; k < g.lines->size(); ++k) stack.addLine((*g.lines)[k]);
            }
            Flow flow;
            flow.cursor = bodyTop;
            i64 usedCursor = bodyTop;
            int best = -1;
            bool forced = false;
            for (int j = i + 1;; ++j) {
                const VItem& it = items[j - 1];
                if (it.kind == VItem::ForceBreak) {
                    cut = j - 1;
                    forced = true;
                    break;
                }
                switch (it.kind) {
                    case VItem::Line: {
                        const PlacedLine& l = in.list.lines[it.index];
                        flow.line(l.ascent, l.depth, it.leading, s.lineSkip);
                        usedCursor = flow.cursor;
                        if (haveFootnotes)
                            for (int fn : l.footnotes) {
                                stack.startGroup();
                                for (const PlacedLine& fl : (*in.footnotes)[fn - 1]) stack.addLine(fl);
                            }
                        break;
                    }
                    case VItem::Glue:
                        flow.cursor += it.height;
                        flow.fresh = true;
                        break;
                    case VItem::Rule:
                    case VItem::RowItem:
                        flow.cursor += it.height;
                        flow.fresh = true;
                        usedCursor = flow.cursor;
                        break;
                    default:
                        usedCursor = flow.cursor;
                        break;
                }
                i64 used = (usedCursor - bodyTop) + std::min(stack.area(), s.footnoteMaxHeight);
                if (used > goal) break;
                if (legal[j]) best = j;
                if (j == n) break;
            }
            if (!forced) {
                if (best >= 0) {
                    cut = best;
                } else {
                    cut = n;
                    for (int j = i + 1; j <= n; ++j)
                        if (legal[j]) { cut = j; break; }
                }
            }
        }

        // 4. place the body
        int end = cut;
        while (end > i && items[end - 1].kind == VItem::Glue) --end;
        const bool bodyEmpty = end == i;
        {
            Flow flow;
            flow.cursor = bodyTop;
            for (int j = i; j < end; ++j) {
                const VItem& it = items[j];
                switch (it.kind) {
                    case VItem::Line: {
                        const PlacedLine& l = in.list.lines[it.index];
                        i64 baseline = flow.line(l.ascent, l.depth, it.leading, s.lineSkip);
                        emitLine(page.items, Region::Body, l, baseline, stats);
                        if (it.headingId >= 0 && in.headings) {
                            HeadingInfo& h = (*in.headings)[it.headingId];
                            h.page = pageNo;
                            if (h.level == 1) chapter = it.headingId;
                            if (h.level == 2) section = it.headingId;
                        }
                        break;
                    }
                    case VItem::Glue:
                        flow.cursor += it.height;
                        flow.fresh = true;
                        break;
                    case VItem::Rule: {
                        OutItem o;
                        o.kind = OutItem::RuleItem;
                        o.region = Region::Body;
                        o.x = it.x;
                        o.y = flow.cursor;
                        o.width = it.width;
                        o.height = it.height;
                        page.items.push_back(o);
                        flow.cursor += it.height;
                        flow.fresh = true;
                        break;
                    }
                    case VItem::RowItem: {
                        const Row& row = in.list.rows[it.index];
                        for (const RowLine& rl : row.lines) emitLine(page.items, Region::Body, rl.line, flow.cursor + rl.baselineOffset, stats);
                        flow.cursor += row.height;
                        flow.fresh = true;
                        break;
                    }
                    default: break;
                }
            }
            const i64 B = flow.cursor - bodyTop;

            // 5. footnotes
            if (haveFootnotes) {
                std::vector<FnGroup> cand = carried;
                for (int j = i; j < end; ++j) {
                    if (items[j].kind != VItem::Line) continue;
                    for (int fn : in.list.lines[items[j].index].footnotes) {
                        const auto& fl = (*in.footnotes)[fn - 1];
                        cand.push_back({fn, &fl, 0, fl.size(), true});
                    }
                }
                const i64 avail = goal - B - s.footnoteSpaceBefore - s.footnoteRuleThickness - s.footnoteSpaceAfter;
                FootnotePlan plan = planFootnotes(s, cand, avail, bodyEmpty);
                for (const FnGroup& g : plan.rest) stats.footnoteSplitLines += static_cast<i64>(g.size());
                carried = plan.rest;

                if (!plan.placed.empty()) {
                    // Height of the stack, then position it flush with the body bottom.
                    FnStack stack(s);
                    for (const FnGroup& g : plan.placed) {
                        stack.startGroup();
                        for (std::size_t k = g.from; k < g.to; ++k) stack.addLine((*g.lines)[k]);
                    }
                    const i64 Hfn = stack.flow.cursor;
                    const i64 ruleTop = s.bodyBottom() - Hfn - s.footnoteSpaceAfter - s.footnoteRuleThickness;
                    OutItem rule;
                    rule.kind = OutItem::RuleItem;
                    rule.region = Region::Footnote;
                    rule.x = s.bodyX();
                    rule.y = ruleTop;
                    rule.width = s.footnoteRuleWidth;
                    rule.height = s.footnoteRuleThickness;
                    page.items.push_back(rule);
                    const i64 stackTop = ruleTop + s.footnoteRuleThickness + s.footnoteSpaceAfter;
                    const int markFace = faceIndex(s.footnoteFont, false, false);
                    Flow flow;
                    flow.cursor = 0;
                    bool first = true;
                    for (const FnGroup& g : plan.placed) {
                        if (!first) {
                            flow.cursor += s.footnoteItemSpace;
                            flow.fresh = true;
                        }
                        first = false;
                        for (std::size_t k = g.from; k < g.to; ++k) {
                            const PlacedLine& l = (*g.lines)[k];
                            i64 baseline = stackTop + flow.line(l.ascent, l.depth, s.footnoteLeading, s.lineSkip);
                            emitLine(page.items, Region::Footnote, l, baseline, stats);
                            if (k == 0 && g.mark) {
                                OutItem m;
                                m.kind = OutItem::Text;
                                m.region = Region::Footnote;
                                m.face = markFace;
                                m.size = s.footnoteMarkSize;
                                m.text = std::to_string(g.number);
                                m.width = fonts.face(markFace).width(utf8ToU32(m.text), m.size);
                                m.x = s.bodyX() + s.footnoteIndent - s.footnoteMarkGap - m.width;
                                m.y = baseline - s.footnoteMarkRaise;
                                page.items.push_back(m);
                            }
                        }
                    }
                }
            }
        }

        // 6. figures referenced by this page join the queue; the zone's figures are drawn now
        for (int j = i; j < cut; ++j)
            if (items[j].kind == VItem::FloatMark) queue.push_back(items[j].index);
        {
            i64 y = s.bodyY();
            for (int fi : taken) {
                const FigureBlock& fig = (*in.figures)[fi];
                if (fig.frame) {
                    OutItem box;
                    box.kind = OutItem::BoxItem;
                    box.region = Region::Float;
                    box.x = fig.x;
                    box.y = y;
                    box.width = fig.width;
                    box.height = fig.frameHeight;
                    page.items.push_back(box);
                }
                for (const RowLine& rl : fig.caption) emitLine(page.items, Region::Float, rl.line, y + rl.baselineOffset, stats);
                y += fig.height + s.floatSpaceAfter;
            }
        }
        page.chapter = chapter;
        page.section = section;
        pages.push_back(std::move(page));
        i = cut;
    }
    return pages;
}

}  // namespace typeset
