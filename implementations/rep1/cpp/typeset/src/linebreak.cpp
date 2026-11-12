#include "typeset/linebreak.hpp"

#include <algorithm>
#include <cstdlib>
#include <limits>

namespace typeset {

namespace {

enum Fitness { Tight = 0, Decent = 1, Loose = 2, VeryLoose = 3 };

struct LineEval {
    bool unstretchable = false;
    bool overfull = false;
    i64 badness = 0;
    int fitness = Decent;
};

i64 badnessOf(i64 num, i64 den) {
    __int128 n = static_cast<__int128>(num) * num * num * 100;
    __int128 d = static_cast<__int128>(den) * den * den;
    __int128 q = n / d;
    return q > 10000 ? 10000 : static_cast<i64>(q);
}

LineEval evaluate(const HList::Measure& m, i64 L) {
    LineEval r;
    i64 d = L - m.width;
    if (d >= 0 && m.infinite) return r;
    if (d == 0) return r;
    if (d > 0) {
        if (m.stretch == 0) {
            r.unstretchable = true;
            r.badness = 10000;
            r.fitness = VeryLoose;
            return r;
        }
        r.badness = badnessOf(d, m.stretch);
        r.fitness = d > m.stretch ? VeryLoose : (2 * d > m.stretch ? Loose : Decent);
        return r;
    }
    i64 e = -d;
    if (m.shrink == 0 || e > m.shrink) {
        r.overfull = true;
        r.badness = 10000;
        r.fitness = Tight;
        return r;
    }
    r.badness = badnessOf(e, m.shrink);
    r.fitness = 2 * e > m.shrink ? Tight : Decent;
    return r;
}

struct Node {
    int bp;
    int cls;
    i64 total;
    int prev;
};

class Breaker {
public:
    Breaker(const HList& list, const Settings& s) : list_(list), s_(s) {}

    bool run(bool second, BreakResult& out) {
        nodes_.clear();
        nodes_.push_back({0, Decent, 0, -1});
        std::vector<int> active{0};
        const int finalIdx = list_.finalIndex();
        const Context& ctx = list_.context;
        int firstFinalNode = -1;

        for (int b : list_.breakpoints) {
            if (active.empty()) return false;
            const bool isFinal = b == finalIdx;
            const Item& bi = list_.items[b];
            const i64 pen = bi.kind == Item::Penalty ? bi.penalty : 0;
            const bool flag = bi.kind == Item::Penalty && bi.flagged;
            i64 bestTotal[4];
            int bestPrev[4];
            for (int c = 0; c < 4; ++c) { bestTotal[c] = std::numeric_limits<i64>::max(); bestPrev[c] = -1; }

            std::size_t keep = 0;
            for (std::size_t ai = 0; ai < active.size(); ++ai) {
                int idx = active[ai];
                const Node& n = nodes_[idx];
                const i64 L = n.bp == 0 ? ctx.measure - ctx.firstIndent : ctx.measure;
                HList::Measure m = list_.measure(n.bp, b);
                if (!second) {
                    if (m.widthNoPre - m.shrink > L) continue;  // overfull for good: leaves the active set
                    active[keep++] = idx;
                } else {
                    keep = ai + 1;
                }
                LineEval ev = evaluate(m, L);
                if (!second && (ev.unstretchable || ev.overfull || ev.badness > s_.tolerance)) continue;

                i64 dem = (s_.linePenalty + ev.badness) * (s_.linePenalty + ev.badness);
                if (pen >= 0 && pen < 10000) dem += pen * pen;
                else if (pen > -10000 && pen < 0) dem -= pen * pen;
                const bool flag0 = n.bp != 0 && list_.items[n.bp].kind == Item::Penalty && list_.items[n.bp].flagged;
                if (flag && flag0) dem += s_.doubleHyphenDemerits;
                if (std::abs(ev.fitness - n.cls) > 1) dem += s_.adjDemerits;
                if (isFinal && flag0) dem += s_.finalHyphenDemerits;
                i64 total = n.total + dem;
                if (total < bestTotal[ev.fitness]) {
                    bestTotal[ev.fitness] = total;
                    bestPrev[ev.fitness] = idx;
                }
            }
            active.resize(keep);
            for (int c = 0; c < 4; ++c) {
                if (bestPrev[c] < 0) continue;
                if (isFinal && firstFinalNode < 0) firstFinalNode = static_cast<int>(nodes_.size());
                nodes_.push_back({b, c, bestTotal[c], bestPrev[c]});
                active.push_back(static_cast<int>(nodes_.size()) - 1);
            }
            if (isFinal) {
                if (firstFinalNode < 0) return false;
                int best = firstFinalNode;
                for (int i = firstFinalNode; i < static_cast<int>(nodes_.size()); ++i)
                    if (nodes_[i].total < nodes_[best].total) best = i;
                out.demerits = nodes_[best].total;
                out.breaks.clear();
                for (int i = best; nodes_[i].prev >= 0; i = nodes_[i].prev) out.breaks.push_back(nodes_[i].bp);
                std::reverse(out.breaks.begin(), out.breaks.end());
                return true;
            }
        }
        return false;
    }

private:
    const HList& list_;
    const Settings& s_;
    std::vector<Node> nodes_;
};

}  // namespace

BreakResult breakIntoLines(const HList& list, const Settings& settings) {
    BreakResult r;
    Breaker br(list, settings);
    if (br.run(false, r)) return r;
    r = BreakResult{};
    r.emergency = true;
    br.run(true, r);
    return r;
}

namespace {

/// Distribute `total` over weights as in the specification (floor division
/// of cumulative shares); returns the increment of each glue.
void distribute(std::vector<i64>& widths, const std::vector<i64>& weights, i64 total) {
    i64 T = 0;
    for (i64 w : weights) T += w;
    i64 P = 0, prevC = 0;
    for (std::size_t i = 0; i < widths.size(); ++i) {
        P += weights[i];
        __int128 num = static_cast<__int128>(total) * P;
        __int128 q = num / T;
        if (num % T != 0 && num < 0) --q;
        i64 C = static_cast<i64>(q);
        widths[i] += C - prevC;
        prevC = C;
    }
}

PlacedLine setLine(const HList& list, int a, int b, const FontSet& fonts, Stats& stats) {
    const Context& ctx = list.context;
    const bool first = a == 0;
    const i64 L = first ? ctx.measure - ctx.firstIndent : ctx.measure;
    const i64 leftLine = ctx.left + (first ? ctx.firstIndent : 0);
    const int s = list.lineStart(a, b);
    const HList::Measure m = list.measure(a, b);

    std::vector<i64> glueW, glueY, glueZ;
    for (int i = s; i < b; ++i) {
        const Item& it = list.items[i];
        if (it.kind != Item::Glue) continue;
        glueW.push_back(it.width);
        glueY.push_back(it.stretch);
        glueZ.push_back(it.shrink);
    }
    if (m.infinite) {
        std::size_t g = 0;
        for (int i = s; i < b; ++i) {
            const Item& it = list.items[i];
            if (it.kind != Item::Glue) continue;
            if (it.infinite) glueW[g] = 0;
            ++g;
        }
    } else if (ctx.align == Align::Justify) {
        i64 E = L - m.width;
        if (E == 0 || (E > 0 && m.stretch == 0) || (E < 0 && m.shrink == 0)) {
        } else if (E > 0) {
            distribute(glueW, glueY, E);
        } else if (-E <= m.shrink) {
            distribute(glueW, glueZ, E);
        } else {
            for (std::size_t g = 0; g < glueW.size(); ++g) glueW[g] -= glueZ[g];
        }
    }

    i64 wset = 0;
    {
        std::size_t g = 0;
        for (int i = s; i < b; ++i) {
            const Item& it = list.items[i];
            if (it.kind == Item::Box) wset += it.width;
            else if (it.kind == Item::Glue) wset += glueW[g++];
        }
        if (list.items[b].kind == Item::Penalty) wset += list.items[b].preWidth;
    }

    PlacedLine line;
    i64 x = leftLine;
    switch (ctx.align) {
        case Align::Justify: case Align::Left: break;
        case Align::Right: x = leftLine + L - wset; break;
        case Align::Center: x = leftLine + floorDiv(L - wset, 2); break;
    }
    line.startX = x;
    line.endX = x + wset;

    bool sawText = false;
    i64 asc = 0, dep = 0;
    auto noteMetrics = [&](int face, i64 size, i64 raise) {
        const Face& f = fonts.face(face);
        i64 a1 = scaleUnits(f.ascent, size) + raise;
        i64 d1 = std::max<i64>(0, scaleUnits(f.descent, size) - raise);
        if (!sawText) { asc = a1; dep = d1; sawText = true; }
        else { asc = std::max(asc, a1); dep = std::max(dep, d1); }
    };

    int lastRun = -1;
    std::size_t g = 0;
    for (int i = s; i < b; ++i) {
        const Item& it = list.items[i];
        if (it.kind == Item::Glue) {
            x += glueW[g++];
            lastRun = -1;
        } else if (it.kind == Item::Box) {
            if (it.rigid) {
                x += it.width;
                lastRun = -1;
                continue;
            }
            noteMetrics(it.face, it.size, it.raise);
            if (it.footnote) line.footnotes.push_back(it.footnote);
            if (lastRun >= 0 && list.items[lastRun].fragment == it.fragment) {
                Run& r = line.runs.back();
                r.text += it.text;
                r.width += it.width;
            } else {
                line.runs.push_back({it.face, it.size, x, it.raise, it.width, it.text});
                lastRun = i;
            }
            x += it.width;
        }
    }
    const Item& bi = list.items[b];
    if (bi.kind == Item::Penalty && !bi.preText.empty()) {
        if (lastRun >= 0 && !line.runs.empty() && list.items[lastRun].fragment == bi.fragment) {
            line.runs.back().text += bi.preText;
            line.runs.back().width += bi.preWidth;
        } else {
            line.runs.push_back({bi.face, bi.size, x, 0, bi.preWidth, bi.preText});
        }
        ++stats.hyphenatedLines;
    }
    if (!sawText) {
        const Face& f = fonts.face(HListBuilder::contextFace(ctx));
        asc = scaleUnits(f.ascent, ctx.size);
        dep = scaleUnits(f.descent, ctx.size);
    }
    line.ascent = asc;
    line.depth = dep;
    if (wset > L) ++stats.overfullLines;
    return line;
}

}  // namespace

std::vector<PlacedLine> setLines(const HList& list, const std::vector<int>& breaks, const FontSet& fonts, Stats& stats) {
    std::vector<PlacedLine> out;
    int prev = 0;
    for (int b : breaks) {
        out.push_back(setLine(list, prev, b, fonts, stats));
        prev = b;
    }
    return out;
}

std::vector<PlacedLine> typesetList(const HList& list, const Settings& settings, const FontSet& fonts, Stats& stats) {
    BreakResult r = breakIntoLines(list, settings);
    stats.totalDemerits += r.demerits;
    if (r.emergency) ++stats.emergencyLists;
    return setLines(list, r.breaks, fonts, stats);
}

}  // namespace typeset
