//! The document walk: property inheritance, transforms, `use` expansion,
//! group opacity and painting of fills and strokes.

use crate::canvas::Canvas;
use crate::color::{parse_paint, Paint, Rgb};
use crate::error::Error;
use crate::geom::{Matrix, Point};
use crate::number::{parse_length, parse_number_list, parse_opacity, trim_ws};
use crate::path::{flatten, Path};
use crate::raster::{scan, FillRule};
use crate::stroke::{outline, LineCap, LineJoin, StrokeStyle};
use crate::style::Declarations;
use crate::transform::parse_transform;
use crate::xml::{Document, Element, NodeId};
use std::collections::HashMap;

/// Flattening tolerance in device pixels.
const TOLERANCE: f64 = 0.01;
/// Maximum nesting depth (counting `use` expansion).
const MAX_DEPTH: usize = 64;

/// The inherited painting properties of an element.
#[derive(Clone, Debug)]
struct Style {
    fill: Paint,
    fill_opacity: f64,
    fill_rule: FillRule,
    stroke: Paint,
    stroke_width: f64,
    cap: LineCap,
    join: LineJoin,
    miter_limit: f64,
    stroke_opacity: f64,
    color: Rgb,
}

impl Style {
    fn initial() -> Style {
        Style {
            fill: Paint::Color(Rgb::BLACK),
            fill_opacity: 1.0,
            fill_rule: FillRule::NonZero,
            stroke: Paint::None,
            stroke_width: 1.0,
            cap: LineCap::Butt,
            join: LineJoin::Miter,
            miter_limit: 4.0,
            stroke_opacity: 1.0,
            color: Rgb::BLACK,
        }
    }

    /// Computes an element's style from its parent's: `style` attribute,
    /// then presentation attribute, then inheritance. A value that fails to
    /// parse falls back to the property's initial value.
    fn compute(parent: &Style, el: &Element, decls: &Declarations) -> Style {
        let init = Style::initial();
        let mut s = parent.clone();
        let prop = |name: &str| -> Option<&str> {
            decls.get(name).or_else(|| el.attr(name).filter(|v| !trim_ws(v).is_empty()))
        };
        if let Some(v) = prop("color") {
            s.color = match parse_paint(v) {
                Some(Paint::Color(c)) => c,
                Some(Paint::CurrentColor) => parent.color,
                _ => init.color,
            };
        }
        if let Some(v) = prop("fill") {
            s.fill = parse_paint(v).unwrap_or(init.fill);
        }
        if let Some(v) = prop("stroke") {
            s.stroke = parse_paint(v).unwrap_or(init.stroke);
        }
        if let Some(v) = prop("fill-opacity") {
            s.fill_opacity = parse_opacity(v).unwrap_or(init.fill_opacity);
        }
        if let Some(v) = prop("stroke-opacity") {
            s.stroke_opacity = parse_opacity(v).unwrap_or(init.stroke_opacity);
        }
        if let Some(v) = prop("fill-rule") {
            s.fill_rule = match v {
                "nonzero" => FillRule::NonZero,
                "evenodd" => FillRule::EvenOdd,
                _ => init.fill_rule,
            };
        }
        if let Some(v) = prop("stroke-width") {
            s.stroke_width = parse_length(v).unwrap_or(init.stroke_width);
        }
        if let Some(v) = prop("stroke-linecap") {
            s.cap = match v {
                "butt" => LineCap::Butt,
                "round" => LineCap::Round,
                "square" => LineCap::Square,
                _ => init.cap,
            };
        }
        if let Some(v) = prop("stroke-linejoin") {
            s.join = match v {
                "miter" => LineJoin::Miter,
                "round" => LineJoin::Round,
                "bevel" => LineJoin::Bevel,
                _ => init.join,
            };
        }
        if let Some(v) = prop("stroke-miterlimit") {
            s.miter_limit = parse_length(v).unwrap_or(init.miter_limit).max(1.0);
        }
        s
    }
}

struct Renderer<'a> {
    doc: &'a Document,
    ids: HashMap<&'a str, NodeId>,
    canvas: Canvas,
}

/// Renders SVG source text to a `width x height` canvas.
///
/// The canvas is transparent where nothing is drawn; [`Canvas::to_ppm`]
/// composites it over white.
pub fn render_svg(src: &str, width: usize, height: usize) -> Result<Canvas, Error> {
    let doc = Document::parse(src)?;
    let root = doc.get(doc.root());
    if root.tag != "svg" {
        return Err(Error::NotSvg(root.tag.clone()));
    }
    let (vx, vy, vw, vh) = view_rect(root, width as f64, height as f64);
    let sx = width as f64 / vw;
    let sy = height as f64 / vh;
    let ctm0 = Matrix { a: sx, b: 0.0, c: 0.0, d: sy, e: -vx * sx, f: -vy * sy };

    let mut ids = HashMap::new();
    for id in doc.iter_ids() {
        if let Some(v) = doc.get(id).attr("id") {
            ids.entry(v).or_insert(id);
        }
    }
    let mut r = Renderer { doc: &doc, ids, canvas: Canvas::new(width, height) };
    r.node(doc.root(), &Style::initial(), &ctm0, 0);
    Ok(r.canvas)
}

/// Determines the user-space view rectangle of the document element.
fn view_rect(root: &Element, w: f64, h: f64) -> (f64, f64, f64, f64) {
    if let Some(vb) = root.attr("viewBox") {
        let n = parse_number_list(vb);
        if n.len() >= 4 && n[2] > 0.0 && n[3] > 0.0 {
            return (n[0], n[1], n[2], n[3]);
        }
    }
    let len = |name: &str| root.attr(name).and_then(parse_length);
    if let (Some(a), Some(b)) = (len("width"), len("height")) {
        if a > 0.0 && b > 0.0 {
            return (0.0, 0.0, a, b);
        }
    }
    (0.0, 0.0, w, h)
}

fn num(el: &Element, name: &str) -> Option<f64> {
    el.attr(name).and_then(parse_length)
}

fn num_or0(el: &Element, name: &str) -> f64 {
    num(el, name).unwrap_or(0.0)
}

impl Renderer<'_> {
    fn node(&mut self, id: NodeId, parent: &Style, parent_ctm: &Matrix, depth: usize) {
        if depth > MAX_DEPTH {
            return;
        }
        let el = self.doc.get(id);
        let renderable = match el.tag.as_str() {
            "svg" => depth == 0,
            "g" | "use" | "path" | "rect" | "circle" | "ellipse" | "line" | "polyline" | "polygon" => true,
            _ => false,
        };
        if !renderable {
            return;
        }
        let decls = el.attr("style").map(Declarations::parse).unwrap_or_default();
        let display = decls.get("display").or_else(|| el.attr("display"));
        if display.map(trim_ws) == Some("none") {
            return;
        }
        let opacity = decls
            .get("opacity")
            .or_else(|| el.attr("opacity"))
            .and_then(parse_opacity)
            .unwrap_or(1.0);
        if opacity <= 0.0 {
            return;
        }
        let mut ctm = *parent_ctm;
        if let Some(t) = el.attr("transform") {
            ctm = ctm.mul(&parse_transform(t));
        }
        let style = Style::compute(parent, el, &decls);

        if opacity < 1.0 {
            let (w, h) = (self.canvas.width(), self.canvas.height());
            let saved = std::mem::replace(&mut self.canvas, Canvas::new(w, h));
            self.content(id, &style, &ctm, depth);
            let layer = std::mem::replace(&mut self.canvas, saved);
            self.canvas.draw_layer(&layer, opacity);
        } else {
            self.content(id, &style, &ctm, depth);
        }
    }

    fn content(&mut self, id: NodeId, style: &Style, ctm: &Matrix, depth: usize) {
        let el = self.doc.get(id);
        match el.tag.as_str() {
            "svg" | "g" => {
                for &c in &el.children {
                    self.node(c, style, ctm, depth + 1);
                }
            }
            "use" => {
                let target = el
                    .attr("href")
                    .map(trim_ws)
                    .and_then(|h| h.strip_prefix('#'))
                    .and_then(|name| self.ids.get(name).copied());
                if let Some(t) = target {
                    let m = ctm.mul(&Matrix::translate(num_or0(el, "x"), num_or0(el, "y")));
                    self.node(t, style, &m, depth + 1);
                }
            }
            _ => {
                if let Some((path, fillable)) = shape_path(el) {
                    self.paint(&path, fillable, style, ctm);
                }
            }
        }
    }

    fn paint(&mut self, path: &Path, fillable: bool, style: &Style, ctm: &Matrix) {
        let resolve = |p: Paint| match p {
            Paint::None => None,
            Paint::CurrentColor => Some(style.color),
            Paint::Color(c) => Some(c),
        };
        if fillable && style.fill_opacity > 0.0 {
            if let Some(c) = resolve(style.fill) {
                let polys: Vec<Vec<Point>> = flatten(path, ctm, TOLERANCE)
                    .into_iter()
                    .map(|s| s.points)
                    .filter(|p| p.len() >= 3)
                    .collect();
                self.fill(&polys, style.fill_rule, c, style.fill_opacity);
            }
        }
        if style.stroke_width > 0.0 && style.stroke_opacity > 0.0 {
            if let Some(c) = resolve(style.stroke) {
                let scale = ctm.max_scale();
                if scale > 0.0 && scale.is_finite() {
                    let tol = TOLERANCE / scale;
                    let subs = flatten(path, &Matrix::IDENTITY, tol);
                    let ss = StrokeStyle {
                        width: style.stroke_width,
                        cap: style.cap,
                        join: style.join,
                        miter_limit: style.miter_limit,
                    };
                    let mut polys = outline(&subs, &ss, tol);
                    for poly in polys.iter_mut() {
                        for p in poly.iter_mut() {
                            *p = ctm.apply(*p);
                        }
                    }
                    self.fill(&polys, FillRule::NonZero, c, style.stroke_opacity);
                }
            }
        }
    }

    fn fill(&mut self, polys: &[Vec<Point>], rule: FillRule, color: Rgb, opacity: f64) {
        let rgb = color.to_unit();
        let (w, h) = (self.canvas.width(), self.canvas.height());
        let canvas = &mut self.canvas;
        scan(polys, rule, w, h, |row, x0, cov| canvas.blend_row(row, x0, cov, rgb, opacity));
    }
}

/// Converts a shape element to a path; the flag says whether it can be
/// filled (lines cannot). Returns `None` for elements that draw nothing.
fn shape_path(el: &Element) -> Option<(Path, bool)> {
    match el.tag.as_str() {
        "path" => Some((Path::parse(el.attr("d")?), true)),
        "rect" => {
            let r = |name: &str| match el.attr(name) {
                Some(v) if trim_ws(v) == "auto" => None,
                Some(v) => parse_length(v),
                None => None,
            };
            Path::rect(num_or0(el, "x"), num_or0(el, "y"), num_or0(el, "width"), num_or0(el, "height"), r("rx"), r("ry"))
                .map(|p| (p, true))
        }
        "circle" => {
            let r = num_or0(el, "r");
            Path::ellipse(num_or0(el, "cx"), num_or0(el, "cy"), r, r).map(|p| (p, true))
        }
        "ellipse" => {
            Path::ellipse(num_or0(el, "cx"), num_or0(el, "cy"), num_or0(el, "rx"), num_or0(el, "ry")).map(|p| (p, true))
        }
        "line" => Some((Path::line(num_or0(el, "x1"), num_or0(el, "y1"), num_or0(el, "x2"), num_or0(el, "y2")), false)),
        "polyline" | "polygon" => {
            let coords = parse_number_list(el.attr("points").unwrap_or(""));
            Path::poly(&coords, el.tag == "polygon").map(|p| (p, true))
        }
        _ => None,
    }
}
