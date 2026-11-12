#include "svgraster/style.hpp"

namespace svgraster {

namespace {

// Looks a property up: `style` attribute first, then the presentation
// attribute. Empty values count as absent.
class Lookup {
public:
    explicit Lookup(const Element& el) : el_(el) {
        if (const std::string* s = el.attr("style")) decls_ = parse_style(*s);
    }

    const std::string* get(const char* name) const {
        auto it = decls_.find(name);
        if (it != decls_.end()) return &it->second;
        const std::string* a = el_.attr(name);
        if (a && !trim(*a).empty()) return a;
        return nullptr;
    }

private:
    const Element& el_;
    std::map<std::string, std::string> decls_;
};

Paint parse_paint(const std::string& raw, const Paint& initial) {
    std::string s = trim(raw);
    std::string l = to_lower(s);
    if (l == "none") return {Paint::Kind::None, {}};
    if (l == "currentcolor") return {Paint::Kind::CurrentColor, {}};
    if (auto c = parse_color(s)) return {Paint::Kind::Color, *c};
    return initial;
}

}  // namespace

Style compute_style(const Element& el, const Style& parent) {
    Style init;
    Style st = parent;
    Lookup lk(el);
    if (auto v = lk.get("color")) {
        auto c = parse_color(*v);
        st.color = c ? *c : init.color;
    }
    if (auto v = lk.get("fill")) st.fill = parse_paint(*v, init.fill);
    if (auto v = lk.get("stroke")) st.stroke = parse_paint(*v, init.stroke);
    if (auto v = lk.get("fill-opacity")) st.fill_opacity = parse_opacity(*v).value_or(init.fill_opacity);
    if (auto v = lk.get("stroke-opacity")) st.stroke_opacity = parse_opacity(*v).value_or(init.stroke_opacity);
    if (auto v = lk.get("fill-rule")) {
        std::string s = trim(*v);
        st.fill_rule = s == "evenodd" ? FillRule::EvenOdd : FillRule::NonZero;
    }
    if (auto v = lk.get("stroke-width")) st.stroke_width = parse_length(*v).value_or(init.stroke_width);
    if (auto v = lk.get("stroke-miterlimit")) st.miter_limit = parse_length(*v).value_or(init.miter_limit);
    if (auto v = lk.get("stroke-linecap")) {
        std::string s = trim(*v);
        st.line_cap = s == "round" ? LineCap::Round : s == "square" ? LineCap::Square : LineCap::Butt;
    }
    if (auto v = lk.get("stroke-linejoin")) {
        std::string s = trim(*v);
        st.line_join = s == "round" ? LineJoin::Round : s == "bevel" ? LineJoin::Bevel : LineJoin::Miter;
    }
    return st;
}

bool is_display_none(const Element& el) {
    Lookup lk(el);
    auto v = lk.get("display");
    return v && trim(*v) == "none";
}

double computed_opacity(const Element& el) {
    Lookup lk(el);
    auto v = lk.get("opacity");
    return v ? parse_opacity(*v).value_or(1.0) : 1.0;
}

}  // namespace svgraster
