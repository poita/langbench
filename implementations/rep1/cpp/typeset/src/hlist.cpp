#include "typeset/hlist.hpp"

#include <algorithm>
#include <map>

namespace typeset {

// ------------------------------------------------------------------- HList

void HList::finish() {
    const std::size_t n = items.size();
    cumW_.assign(n + 1, 0);
    cumY_.assign(n + 1, 0);
    cumZ_.assign(n + 1, 0);
    cumInf_.assign(n + 1, 0);
    skipGlue_.assign(n + 1, static_cast<int>(n));
    breakpoints.clear();
    for (std::size_t i = 0; i < n; ++i) {
        const Item& it = items[i];
        i64 w = 0, y = 0, z = 0;
        int inf = 0;
        if (it.kind == Item::Box) {
            w = it.width;
        } else if (it.kind == Item::Glue) {
            w = it.width;
            y = it.stretch;
            z = it.shrink;
            if (it.infinite) inf = 1;
        }
        cumW_[i + 1] = cumW_[i] + w;
        cumY_[i + 1] = cumY_[i] + y;
        cumZ_[i + 1] = cumZ_[i] + z;
        cumInf_[i + 1] = cumInf_[i] + inf;
        if (i > 0) {
            if (it.kind == Item::Glue && items[i - 1].kind == Item::Box) breakpoints.push_back(static_cast<int>(i));
            else if (it.kind == Item::Penalty && it.penalty < 10000) breakpoints.push_back(static_cast<int>(i));
        }
    }
    for (std::size_t i = n; i-- > 0;) {
        const Item& it = items[i];
        skipGlue_[i] = (it.kind == Item::Glue && !it.infinite) ? skipGlue_[i + 1] : static_cast<int>(i);
    }
}

int HList::lineStart(int a, int b) const {
    int start = a == 0 ? 0 : a + 1;
    return std::min(skipGlue_[start], b);
}

HList::Measure HList::measure(int a, int b) const {
    int s = lineStart(a, b);
    Measure m;
    m.widthNoPre = cumW_[b] - cumW_[s];
    m.width = m.widthNoPre + (items[b].kind == Item::Penalty ? items[b].preWidth : 0);
    m.stretch = cumY_[b] - cumY_[s];
    m.shrink = cumZ_[b] - cumZ_[s];
    m.infinite = cumInf_[b] - cumInf_[s] > 0;
    return m;
}

i64 HList::naturalWidth() const { return cumW_.back(); }

i64 HList::minWidth() const {
    i64 best = 0;
    int prev = 0;
    for (int b : breakpoints) {
        best = std::max(best, measure(prev, b).width);
        prev = b;
    }
    return best;
}

// ------------------------------------------------------------- hyphenation

namespace {
bool isLetter(char32_t c) { return (c >= U'a' && c <= U'z') || (c >= U'A' && c <= U'Z'); }
}  // namespace

std::vector<HyphenPoint> hyphenationPoints(const std::u32string& chars, const std::vector<std::size_t>& discretionary,
                                           const PatternSet& patterns) {
    const std::size_t n = chars.size();
    std::size_t lo = 0, hi = n;
    while (lo < n && !isLetter(chars[lo])) ++lo;
    while (hi > lo && !isLetter(chars[hi - 1])) --hi;
    if (lo >= hi) return {};

    std::vector<std::size_t> explicitPoints;
    for (std::size_t p : discretionary)
        if (p > 0 && p < n) explicitPoints.push_back(p);
    std::sort(explicitPoints.begin(), explicitPoints.end());
    explicitPoints.erase(std::unique(explicitPoints.begin(), explicitPoints.end()), explicitPoints.end());

    std::map<std::size_t, bool> points;  // position -> exHyphen
    for (std::size_t i = lo; i < hi; ++i)
        if (chars[i] == U'-') points[i + 1] = true;
    for (std::size_t p : explicitPoints) points.emplace(p, false);

    if (explicitPoints.empty()) {
        std::size_t start = lo;
        for (std::size_t i = lo; i <= hi; ++i) {
            if (i != hi && chars[i] != U'-') continue;
            bool allLetters = i > start;
            std::string word;
            for (std::size_t k = start; k < i && allLetters; ++k) {
                if (!isLetter(chars[k])) allLetters = false;
                else word.push_back(static_cast<char>(chars[k] >= U'A' && chars[k] <= U'Z' ? chars[k] - U'A' + 'a' : chars[k]));
            }
            if (allLetters)
                for (int q : patterns.breaks(word)) points.emplace(start + q, false);
            start = i + 1;
        }
    }
    std::vector<HyphenPoint> out;
    for (auto [pos, ex] : points) out.push_back({pos, ex});
    return out;
}

// ----------------------------------------------------------------- builder

namespace {

struct StyleState {
    Family family;
    bool bold, italic;
    i64 size;
    int face;
};

bool isSentenceSkip(char32_t c) {
    return c == U')' || c == U']' || c == U'}' || c == U'\'' || c == U'"' || c == 0x2019 || c == 0x201D;
}

/// True when the glue at `g` follows a sentence end.
bool followsSentenceEnd(const std::vector<Unit>& units, std::size_t g) {
    std::ptrdiff_t k = static_cast<std::ptrdiff_t>(g) - 1;
    while (k >= 0) {
        const Unit& u = units[k];
        if (u.kind == Unit::Disc) { --k; continue; }
        if (u.kind != Unit::Char) return false;
        if (isSentenceSkip(u.c)) { --k; continue; }
        break;
    }
    if (k < 0) return false;
    char32_t c = units[k].c;
    if (c != U'.' && c != U'!' && c != U'?') return false;
    std::ptrdiff_t j = k - 1;
    while (j >= 0 && units[j].kind == Unit::Disc) --j;
    if (j >= 0 && units[j].kind == Unit::Char && units[j].c >= U'A' && units[j].c <= U'Z') return false;
    return true;
}

}  // namespace

HList HListBuilder::build(const std::vector<Unit>& units, const std::vector<StyleNode>& styles, const Context& ctx) const {
    HList h;
    h.context = ctx;

    std::vector<StyleState> st(std::max<std::size_t>(styles.size(), 1));
    st[0] = {ctx.family, ctx.bold, ctx.italic, ctx.size, 0};
    for (std::size_t i = 1; i < styles.size(); ++i) {
        StyleState s = st[styles[i].parent];
        switch (styles[i].op) {
            case 'b': s.bold = true; break;
            case 'i': s.italic = true; break;
            case 'm': s.family = Family::Mono; break;
            case '+': s.size = floorDiv(s.size * 6, 5); break;
            case '-': s.size = floorDiv(s.size * 5, 6); break;
        }
        st[i] = s;
    }
    for (auto& s : st) s.face = faceIndex(s.family, s.bold, s.italic);

    const bool hyphenOk = ctx.hyphenate && settings_.hyphenate;
    const bool ragged = ctx.align != Align::Justify;
    int nextFragment = 0;

    struct Fragment {
        bool active = false;
        int face = 0;
        i64 size = 0;
        std::u32string chars;
        std::vector<std::size_t> discs;
    } frag;

    auto makeBox = [&](std::u32string_view text, int face, i64 size, i64 raise, int fragId) {
        Item it;
        it.kind = Item::Box;
        it.face = face;
        it.size = size;
        it.raise = raise;
        it.text = u32ToUtf8(text);
        it.width = fonts_.face(face).width(text, size);
        it.fragment = fragId;
        return it;
    };

    auto flush = [&] {
        if (!frag.active) return;
        frag.active = false;
        int fid = nextFragment++;
        std::vector<HyphenPoint> points;
        if (hyphenOk && frag.face != 8) {
            bool letter = false;
            for (char32_t c : frag.chars) letter = letter || isLetter(c);
            if (letter) points = hyphenationPoints(frag.chars, frag.discs, patterns_);
        }
        std::size_t start = 0;
        for (const HyphenPoint& p : points) {
            h.items.push_back(makeBox(std::u32string_view(frag.chars).substr(start, p.pos - start), frag.face, frag.size, 0, fid));
            Item pen;
            pen.kind = Item::Penalty;
            pen.flagged = true;
            pen.fragment = fid;
            pen.face = frag.face;
            pen.size = frag.size;
            if (p.exHyphen) {
                pen.penalty = settings_.exHyphenPenalty;
            } else {
                pen.penalty = settings_.hyphenPenalty;
                pen.preText = "-";
                pen.preWidth = fonts_.face(frag.face).width(U"-", frag.size);
            }
            h.items.push_back(std::move(pen));
            start = p.pos;
        }
        h.items.push_back(makeBox(std::u32string_view(frag.chars).substr(start), frag.face, frag.size, 0, fid));
        frag.chars.clear();
        frag.discs.clear();
    };

    for (std::size_t k = 0; k < units.size(); ++k) {
        const Unit& u = units[k];
        const StyleState& s = st[u.style];
        switch (u.kind) {
            case Unit::Char:
                if (frag.active && (frag.face != s.face || frag.size != s.size)) flush();
                if (!frag.active) {
                    frag.active = true;
                    frag.face = s.face;
                    frag.size = s.size;
                }
                frag.chars.push_back(u.c);
                break;
            case Unit::Disc:
                if (frag.active) frag.discs.push_back(frag.chars.size());
                break;
            case Unit::Glue: {
                flush();
                const Face& f = fonts_.face(s.face);
                bool extra = !u.plainGlue && followsSentenceEnd(units, k);
                Item g;
                g.kind = Item::Glue;
                if (extra) {
                    g.width = scaleUnits(f.space + f.extra, s.size);
                    g.stretch = scaleUnits(f.stretch + f.stretch / 2, s.size);
                } else {
                    g.width = scaleUnits(f.space, s.size);
                    g.stretch = scaleUnits(f.stretch, s.size);
                }
                g.shrink = scaleUnits(f.shrink, s.size);
                if (ragged) {
                    g.stretch = settings_.raggedStretch * g.width;
                    g.shrink = 0;
                }
                h.items.push_back(std::move(g));
                break;
            }
            case Unit::RigidSpace: {
                flush();
                Item r;
                r.kind = Item::Box;
                r.rigid = true;
                r.width = scaleUnits(fonts_.face(s.face).space, s.size);
                h.items.push_back(std::move(r));
                break;
            }
            case Unit::RigidFixed: {
                flush();
                Item r;
                r.kind = Item::Box;
                r.rigid = true;
                r.width = u.width;
                h.items.push_back(std::move(r));
                break;
            }
            case Unit::Mark: {
                flush();
                Item m = makeBox(utf8ToU32(std::to_string(u.footnote)), s.face, settings_.markSize, settings_.markRaise,
                                 nextFragment++);
                m.footnote = u.footnote;
                h.items.push_back(std::move(m));
                break;
            }
        }
    }
    flush();

    Item p1;
    p1.kind = Item::Penalty;
    p1.penalty = 10000;
    Item g;
    g.kind = Item::Glue;
    g.infinite = true;
    Item p2;
    p2.kind = Item::Penalty;
    p2.penalty = -10000;
    h.items.push_back(p1);
    h.items.push_back(g);
    h.items.push_back(p2);
    h.finish();
    return h;
}

HList HListBuilder::buildVerbatim(std::string_view utf8, const Context& ctx) const {
    HList h;
    h.context = ctx;
    if (!utf8.empty()) {
        Item it;
        it.kind = Item::Box;
        it.face = contextFace(ctx);
        it.size = ctx.size;
        it.text = std::string(utf8);
        it.width = fonts_.face(it.face).width(utf8ToU32(utf8), ctx.size);
        it.fragment = 0;
        h.items.push_back(std::move(it));
    }
    Item p1;
    p1.kind = Item::Penalty;
    p1.penalty = 10000;
    Item g;
    g.kind = Item::Glue;
    g.infinite = true;
    Item p2;
    p2.kind = Item::Penalty;
    p2.penalty = -10000;
    h.items.push_back(p1);
    h.items.push_back(g);
    h.items.push_back(p2);
    h.finish();
    return h;
}

}  // namespace typeset
