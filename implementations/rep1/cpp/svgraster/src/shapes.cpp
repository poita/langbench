#include "svgraster/shapes.hpp"

#include <algorithm>

#include "svgraster/parse.hpp"

namespace svgraster {

namespace {

double len_attr(const Element& el, const char* name, double def = 0) {
    const std::string* v = el.attr(name);
    if (!v) return def;
    auto n = parse_length(*v);
    return n ? *n : def;
}

std::optional<double> opt_len_attr(const Element& el, const char* name) {
    const std::string* v = el.attr(name);
    if (!v || trim(*v) == "auto") return std::nullopt;
    return parse_length(*v);
}

}  // namespace

bool is_shape_tag(const std::string& t) {
    return t == "path" || t == "rect" || t == "circle" || t == "ellipse" || t == "line" ||
           t == "polyline" || t == "polygon";
}

Path rect_path(double x, double y, double w, double h, double rx, double ry) {
    Path p;
    if (rx <= 0 || ry <= 0) {
        p.move_to({x, y});
        p.line_to({x + w, y});
        p.line_to({x + w, y + h});
        p.line_to({x, y + h});
        p.close();
        return p;
    }
    p.move_to({x + rx, y});
    p.line_to({x + w - rx, y});
    p.arc_to(rx, ry, 0, false, true, {x + w, y + ry});
    p.line_to({x + w, y + h - ry});
    p.arc_to(rx, ry, 0, false, true, {x + w - rx, y + h});
    p.line_to({x + rx, y + h});
    p.arc_to(rx, ry, 0, false, true, {x, y + h - ry});
    p.line_to({x, y + ry});
    p.arc_to(rx, ry, 0, false, true, {x + rx, y});
    p.close();
    return p;
}

Path ellipse_path(double cx, double cy, double rx, double ry) {
    Path p;
    p.move_to({cx + rx, cy});
    p.arc_to(rx, ry, 0, false, true, {cx, cy + ry});
    p.arc_to(rx, ry, 0, false, true, {cx - rx, cy});
    p.arc_to(rx, ry, 0, false, true, {cx, cy - ry});
    p.arc_to(rx, ry, 0, false, true, {cx + rx, cy});
    p.close();
    return p;
}

std::optional<Path> shape_to_path(const Element& el) {
    const std::string& t = el.tag;
    if (t == "path") {
        const std::string* d = el.attr("d");
        if (!d) return std::nullopt;
        return parse_path_data(*d);
    }
    if (t == "rect") {
        double w = len_attr(el, "width"), h = len_attr(el, "height");
        if (w <= 0 || h <= 0) return std::nullopt;
        auto rx = opt_len_attr(el, "rx"), ry = opt_len_attr(el, "ry");
        double rxv = 0, ryv = 0;
        if (rx && ry) { rxv = *rx; ryv = *ry; }
        else if (rx) rxv = ryv = *rx;
        else if (ry) rxv = ryv = *ry;
        rxv = std::min(std::max(rxv, 0.0), w / 2);
        ryv = std::min(std::max(ryv, 0.0), h / 2);
        return rect_path(len_attr(el, "x"), len_attr(el, "y"), w, h, rxv, ryv);
    }
    if (t == "circle") {
        double r = len_attr(el, "r");
        if (r <= 0) return std::nullopt;
        return ellipse_path(len_attr(el, "cx"), len_attr(el, "cy"), r, r);
    }
    if (t == "ellipse") {
        double rx = len_attr(el, "rx"), ry = len_attr(el, "ry");
        if (rx <= 0 || ry <= 0) return std::nullopt;
        return ellipse_path(len_attr(el, "cx"), len_attr(el, "cy"), rx, ry);
    }
    if (t == "line") {
        Path p;
        p.move_to({len_attr(el, "x1"), len_attr(el, "y1")});
        p.line_to({len_attr(el, "x2"), len_attr(el, "y2")});
        return p;
    }
    if (t == "polyline" || t == "polygon") {
        const std::string* pts = el.attr("points");
        if (!pts) return std::nullopt;
        std::vector<double> v = parse_number_list(*pts);
        size_t n = v.size() / 2;
        if (n == 0) return std::nullopt;
        Path p;
        p.move_to({v[0], v[1]});
        for (size_t i = 1; i < n; ++i) p.line_to({v[2 * i], v[2 * i + 1]});
        if (t == "polygon") p.close();
        return p;
    }
    return std::nullopt;
}

}  // namespace svgraster
