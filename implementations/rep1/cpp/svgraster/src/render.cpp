#include "svgraster/render.hpp"

#include <map>
#include <memory>

#include "svgraster/parse.hpp"
#include "svgraster/path.hpp"
#include "svgraster/shapes.hpp"
#include "svgraster/stroke.hpp"
#include "svgraster/style.hpp"

namespace svgraster {

namespace {

constexpr int kMaxDepth = 64;

class Renderer {
public:
    Renderer(const Element& root, int w, int h) : root_(root), w_(w), h_(h) { collect_ids(root); }

    Canvas run() {
        Canvas canvas(w_, h_);
        draw(root_, viewport_matrix(), Style(), canvas, 0, true);
        return canvas;
    }

private:
    void collect_ids(const Element& el) {
        if (const std::string* id = el.attr("id")) ids_.emplace(*id, &el);
        for (const auto& c : el.children) collect_ids(*c);
    }

    Matrix viewport_matrix() const {
        double vx = 0, vy = 0, vw = w_, vh = h_;
        bool set = false;
        if (const std::string* vb = root_.attr("viewBox")) {
            std::vector<double> n = parse_number_list(*vb);
            if (n.size() >= 4 && n[2] > 0 && n[3] > 0) {
                vx = n[0]; vy = n[1]; vw = n[2]; vh = n[3];
                set = true;
            }
        }
        if (!set) {
            const std::string* ws = root_.attr("width");
            const std::string* hs = root_.attr("height");
            auto wv = ws ? parse_length(*ws) : std::nullopt;
            auto hv = hs ? parse_length(*hs) : std::nullopt;
            if (wv && hv && *wv > 0 && *hv > 0) { vw = *wv; vh = *hv; }
        }
        double sx = w_ / vw, sy = h_ / vh;
        return {sx, 0, 0, sy, -vx * sx, -vy * sy};
    }

    void draw(const Element& el, const Matrix& parent_ctm, const Style& parent_style, Canvas& canvas, int depth,
              bool is_root) {
        if (depth > kMaxDepth) return;
        const std::string& tag = el.tag;
        const bool container = tag == "g" || (is_root && tag == "svg");
        if (!container && tag != "use" && !is_shape_tag(tag)) return;
        if (is_display_none(el)) return;

        const double opacity = computed_opacity(el);
        if (opacity <= 0) return;
        Style style = compute_style(el, parent_style);
        Matrix ctm = parent_ctm;
        if (const std::string* t = el.attr("transform")) ctm = ctm * parse_transform(*t);

        std::unique_ptr<Canvas> layer;
        Canvas* target = &canvas;
        if (opacity < 1) {
            layer = std::make_unique<Canvas>(w_, h_);
            target = layer.get();
        }

        if (container) {
            for (const auto& c : el.children) draw(*c, ctm, style, *target, depth + 1, false);
        } else if (tag == "use") {
            draw_use(el, ctm, style, *target, depth);
        } else {
            paint_shape(el, ctm, style, *target);
        }

        if (layer) canvas.composite_layer(*layer, opacity);
    }

    void draw_use(const Element& el, const Matrix& ctm, const Style& style, Canvas& canvas, int depth) {
        const std::string* href = el.attr("href");
        if (!href) return;
        std::string h = trim(*href);
        if (h.size() < 2 || h[0] != '#') return;
        auto it = ids_.find(h.substr(1));
        if (it == ids_.end()) return;
        const Element& ref = *it->second;
        if (ref.tag != "g" && !is_shape_tag(ref.tag)) return;
        double x = 0, y = 0;
        if (const std::string* s = el.attr("x")) x = parse_length(*s).value_or(0);
        if (const std::string* s = el.attr("y")) y = parse_length(*s).value_or(0);
        draw(ref, ctm * Matrix::translate(x, y), style, canvas, depth + 1, false);
    }

    void paint_shape(const Element& el, const Matrix& ctm, const Style& st, Canvas& canvas) {
        std::optional<Path> path = shape_to_path(el);
        if (!path || path->empty()) return;

        if (st.fill.kind != Paint::Kind::None && st.fill_opacity > 0) {
            std::vector<Polygon> polys;
            for (Polyline& pl : flatten(*path, ctm, true)) polys.push_back(std::move(pl.pts));
            Rgb c = st.resolve(st.fill);
            fill_polygons(canvas, polys, st.fill_rule, c.r / 255.0, c.g / 255.0, c.b / 255.0, st.fill_opacity);
        }
        if (st.stroke.kind != Paint::Kind::None && st.stroke_width > 0 && st.stroke_opacity > 0) {
            StrokeStyle ss;
            ss.width = st.stroke_width;
            ss.cap = st.line_cap;
            ss.join = st.line_join;
            ss.miter_limit = st.miter_limit;
            auto polys = stroke_polygons(flatten(*path, ctm, false), ss, ctm);
            Rgb c = st.resolve(st.stroke);
            fill_polygons(canvas, polys, FillRule::NonZero, c.r / 255.0, c.g / 255.0, c.b / 255.0,
                          st.stroke_opacity);
        }
    }

    const Element& root_;
    int w_, h_;
    std::map<std::string, const Element*> ids_;
};

}  // namespace

Canvas render_document(const Element& root, int width, int height) {
    return Renderer(root, width, height).run();
}

Canvas render_svg(const std::string& svg_text, int width, int height) {
    std::unique_ptr<Element> root = parse_xml(svg_text);
    if (!root || root->tag != "svg") return Canvas(width, height);
    return render_document(*root, width, height);
}

}  // namespace svgraster
