//! Paths: path-data parsing, elliptical arcs, shape-to-path conversion and
//! curve flattening.

use crate::geom::{Matrix, Point};
use crate::number::parse_number;
use std::f64::consts::PI;

/// One path segment. Paths use only these four kinds.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Segment {
    /// Start a new subpath.
    MoveTo(Point),
    /// Straight line to the point.
    LineTo(Point),
    /// Cubic Bézier: two control points and the end point.
    CubicTo(Point, Point, Point),
    /// Close the current subpath.
    Close,
}

/// A path made of [`Segment`]s.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Path {
    /// The segments in order.
    pub segments: Vec<Segment>,
    cur: Point,
    start: Point,
    need_move: bool,
}

impl Path {
    /// Creates an empty path.
    pub fn new() -> Path {
        Path::default()
    }

    /// Current point.
    pub fn current(&self) -> Point {
        self.cur
    }

    /// Starts a new subpath.
    pub fn move_to(&mut self, p: Point) {
        self.segments.push(Segment::MoveTo(p));
        self.cur = p;
        self.start = p;
        self.need_move = false;
    }

    fn ensure_move(&mut self) {
        if self.need_move {
            let s = self.start;
            self.move_to(s);
        }
    }

    /// Adds a straight line.
    pub fn line_to(&mut self, p: Point) {
        self.ensure_move();
        self.segments.push(Segment::LineTo(p));
        self.cur = p;
    }

    /// Adds a cubic Bézier.
    pub fn cubic_to(&mut self, c1: Point, c2: Point, p: Point) {
        self.ensure_move();
        self.segments.push(Segment::CubicTo(c1, c2, p));
        self.cur = p;
    }

    /// Closes the current subpath. Does nothing if no subpath is open.
    pub fn close(&mut self) {
        if self.need_move || self.segments.is_empty() {
            return;
        }
        self.segments.push(Segment::Close);
        self.cur = self.start;
        self.need_move = true;
    }

    /// Adds an elliptical arc from the current point (SVG 1.1 §F.6).
    pub fn arc_to(&mut self, rx: f64, ry: f64, rot_deg: f64, large: bool, sweep: bool, end: Point) {
        self.ensure_move();
        let from = self.cur;
        if from == end {
            return;
        }
        let (mut rx, mut ry) = (rx.abs(), ry.abs());
        if rx == 0.0 || ry == 0.0 {
            self.line_to(end);
            return;
        }
        let phi = rot_deg.to_radians();
        let (sin_phi, cos_phi) = phi.sin_cos();
        let dx2 = (from.x - end.x) / 2.0;
        let dy2 = (from.y - end.y) / 2.0;
        let x1p = cos_phi * dx2 + sin_phi * dy2;
        let y1p = -sin_phi * dx2 + cos_phi * dy2;
        let lambda = x1p * x1p / (rx * rx) + y1p * y1p / (ry * ry);
        if lambda > 1.0 {
            let s = lambda.sqrt();
            rx *= s;
            ry *= s;
        }
        let num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p;
        let den = rx * rx * y1p * y1p + ry * ry * x1p * x1p;
        let mut coef = if den == 0.0 { 0.0 } else { (num / den).max(0.0).sqrt() };
        if large == sweep {
            coef = -coef;
        }
        let cxp = coef * rx * y1p / ry;
        let cyp = -coef * ry * x1p / rx;
        let cx = cos_phi * cxp - sin_phi * cyp + (from.x + end.x) / 2.0;
        let cy = sin_phi * cxp + cos_phi * cyp + (from.y + end.y) / 2.0;
        let ux = (x1p - cxp) / rx;
        let uy = (y1p - cyp) / ry;
        let vx = (-x1p - cxp) / rx;
        let vy = (-y1p - cyp) / ry;
        let theta1 = uy.atan2(ux);
        let mut dtheta = (ux * vy - uy * vx).atan2(ux * vx + uy * vy);
        if sweep && dtheta < 0.0 {
            dtheta += 2.0 * PI;
        } else if !sweep && dtheta > 0.0 {
            dtheta -= 2.0 * PI;
        }
        let n = ((dtheta.abs() / (PI / 4.0)).ceil() as usize).max(1);
        let delta = dtheta / n as f64;
        let k = 4.0 / 3.0 * (delta / 4.0).tan();
        let point = |t: f64| {
            let (s, c) = t.sin_cos();
            let (px, py) = (rx * c, ry * s);
            Point::new(cx + cos_phi * px - sin_phi * py, cy + sin_phi * px + cos_phi * py)
        };
        let deriv = |t: f64| {
            let (s, c) = t.sin_cos();
            let (px, py) = (-rx * s, ry * c);
            Point::new(cos_phi * px - sin_phi * py, sin_phi * px + cos_phi * py)
        };
        for i in 0..n {
            let t0 = theta1 + i as f64 * delta;
            let t1 = t0 + delta;
            let p3 = if i == n - 1 { end } else { point(t1) };
            let d0 = deriv(t0);
            let d1 = deriv(t1);
            let e0 = point(t0);
            let e1 = point(t1);
            let c1 = Point::new(e0.x + k * d0.x, e0.y + k * d0.y);
            let c2 = Point::new(e1.x - k * d1.x, e1.y - k * d1.y);
            self.segments.push(Segment::CubicTo(c1, c2, p3));
        }
        self.cur = end;
    }

    /// Returns a copy with every point transformed by `m`.
    pub fn transformed(&self, m: &Matrix) -> Path {
        let segments = self
            .segments
            .iter()
            .map(|s| match *s {
                Segment::MoveTo(p) => Segment::MoveTo(m.apply(p)),
                Segment::LineTo(p) => Segment::LineTo(m.apply(p)),
                Segment::CubicTo(a, b, c) => Segment::CubicTo(m.apply(a), m.apply(b), m.apply(c)),
                Segment::Close => Segment::Close,
            })
            .collect();
        Path { segments, cur: m.apply(self.cur), start: m.apply(self.start), need_move: self.need_move }
    }

    /// Parses SVG path data. Parsing stops at the first unexpected token;
    /// commands read before that point are kept.
    pub fn parse(d: &str) -> Path {
        let mut sc = Scanner { b: d.as_bytes(), s: d, i: 0 };
        let mut path = Path::new();
        let mut prev_cubic_ctrl: Option<Point> = None;
        let mut prev_quad_ctrl: Option<Point> = None;
        let mut first = true;
        loop {
            sc.skip_sep();
            let Some(cmd) = sc.peek() else { break };
            if !cmd.is_ascii_alphabetic() || !b"MmLlHhVvCcSsQqTtAaZz".contains(&cmd) {
                break;
            }
            if first && cmd != b'M' && cmd != b'm' {
                break;
            }
            first = false;
            sc.i += 1;
            if cmd == b'Z' || cmd == b'z' {
                path.close();
                prev_cubic_ctrl = None;
                prev_quad_ctrl = None;
                continue;
            }
            let rel = cmd.is_ascii_lowercase();
            let mut upper = cmd.to_ascii_uppercase();
            let mut group = 0;
            loop {
                if group > 0 {
                    sc.skip_sep();
                    match sc.peek() {
                        Some(c) if c == b'+' || c == b'-' || c == b'.' || c.is_ascii_digit() => {}
                        _ => break,
                    }
                }
                let cur = path.current();
                let (ox, oy) = if rel { (cur.x, cur.y) } else { (0.0, 0.0) };
                let ok = match upper {
                    b'M' | b'L' => match sc.numbers::<2>() {
                        Some([x, y]) => {
                            let p = Point::new(x + ox, y + oy);
                            if upper == b'M' {
                                path.move_to(p);
                            } else {
                                path.line_to(p);
                            }
                            true
                        }
                        None => false,
                    },
                    b'H' => sc.numbers::<1>().map(|[x]| path.line_to(Point::new(x + ox, cur.y))).is_some(),
                    b'V' => sc.numbers::<1>().map(|[y]| path.line_to(Point::new(cur.x, y + oy))).is_some(),
                    b'C' => sc
                        .numbers::<6>()
                        .map(|v| {
                            let c1 = Point::new(v[0] + ox, v[1] + oy);
                            let c2 = Point::new(v[2] + ox, v[3] + oy);
                            path.cubic_to(c1, c2, Point::new(v[4] + ox, v[5] + oy));
                            prev_cubic_ctrl = Some(c2);
                        })
                        .is_some(),
                    b'S' => sc
                        .numbers::<4>()
                        .map(|v| {
                            let c1 = match prev_cubic_ctrl {
                                Some(p) => Point::new(2.0 * cur.x - p.x, 2.0 * cur.y - p.y),
                                None => cur,
                            };
                            let c2 = Point::new(v[0] + ox, v[1] + oy);
                            path.cubic_to(c1, c2, Point::new(v[2] + ox, v[3] + oy));
                            prev_cubic_ctrl = Some(c2);
                        })
                        .is_some(),
                    b'Q' => sc
                        .numbers::<4>()
                        .map(|v| {
                            let q = Point::new(v[0] + ox, v[1] + oy);
                            path.quad_to(q, Point::new(v[2] + ox, v[3] + oy));
                            prev_quad_ctrl = Some(q);
                        })
                        .is_some(),
                    b'T' => sc
                        .numbers::<2>()
                        .map(|v| {
                            let q = match prev_quad_ctrl {
                                Some(p) => Point::new(2.0 * cur.x - p.x, 2.0 * cur.y - p.y),
                                None => cur,
                            };
                            path.quad_to(q, Point::new(v[0] + ox, v[1] + oy));
                            prev_quad_ctrl = Some(q);
                        })
                        .is_some(),
                    b'A' => (|| {
                        let [rx, ry, rot] = sc.numbers::<3>()?;
                        let large = sc.flag()?;
                        let sweep = sc.flag()?;
                        let [x, y] = sc.numbers::<2>()?;
                        path.arc_to(rx, ry, rot, large, sweep, Point::new(x + ox, y + oy));
                        Some(())
                    })()
                    .is_some(),
                    _ => false,
                };
                if !ok {
                    return path;
                }
                // Reset the reflection state for commands that do not set it.
                if !matches!(upper, b'C' | b'S') {
                    prev_cubic_ctrl = None;
                }
                if !matches!(upper, b'Q' | b'T') {
                    prev_quad_ctrl = None;
                }
                if upper == b'M' {
                    upper = b'L';
                }
                group += 1;
            }
        }
        path
    }

    /// Adds a quadratic Bézier, converted exactly to a cubic.
    pub fn quad_to(&mut self, q: Point, e: Point) {
        self.ensure_move();
        let c = self.cur;
        let c1 = Point::new(c.x + 2.0 / 3.0 * (q.x - c.x), c.y + 2.0 / 3.0 * (q.y - c.y));
        let c2 = Point::new(e.x + 2.0 / 3.0 * (q.x - e.x), e.y + 2.0 / 3.0 * (q.y - e.y));
        self.cubic_to(c1, c2, e);
    }

    /// The path of a `rect` element, or `None` if nothing is drawn. `rx` and
    /// `ry` are `None` when absent (or `auto`).
    pub fn rect(x: f64, y: f64, w: f64, h: f64, rx: Option<f64>, ry: Option<f64>) -> Option<Path> {
        if w <= 0.0 || h <= 0.0 {
            return None;
        }
        let (rx, ry) = match (rx, ry) {
            (None, None) => (0.0, 0.0),
            (Some(a), None) => (a, a),
            (None, Some(b)) => (b, b),
            (Some(a), Some(b)) => (a, b),
        };
        let rx = rx.max(0.0).min(w / 2.0);
        let ry = ry.max(0.0).min(h / 2.0);
        let mut p = Path::new();
        let pt = Point::new;
        if rx == 0.0 || ry == 0.0 {
            p.move_to(pt(x, y));
            p.line_to(pt(x + w, y));
            p.line_to(pt(x + w, y + h));
            p.line_to(pt(x, y + h));
            p.close();
        } else {
            p.move_to(pt(x + rx, y));
            p.line_to(pt(x + w - rx, y));
            p.arc_to(rx, ry, 0.0, false, true, pt(x + w, y + ry));
            p.line_to(pt(x + w, y + h - ry));
            p.arc_to(rx, ry, 0.0, false, true, pt(x + w - rx, y + h));
            p.line_to(pt(x + rx, y + h));
            p.arc_to(rx, ry, 0.0, false, true, pt(x, y + h - ry));
            p.line_to(pt(x, y + ry));
            p.arc_to(rx, ry, 0.0, false, true, pt(x + rx, y));
            p.close();
        }
        Some(p)
    }

    /// The path of an `ellipse` (or `circle`) element, or `None` if nothing
    /// is drawn.
    pub fn ellipse(cx: f64, cy: f64, rx: f64, ry: f64) -> Option<Path> {
        if rx <= 0.0 || ry <= 0.0 {
            return None;
        }
        let pt = Point::new;
        let mut p = Path::new();
        p.move_to(pt(cx + rx, cy));
        p.arc_to(rx, ry, 0.0, false, true, pt(cx, cy + ry));
        p.arc_to(rx, ry, 0.0, false, true, pt(cx - rx, cy));
        p.arc_to(rx, ry, 0.0, false, true, pt(cx, cy - ry));
        p.arc_to(rx, ry, 0.0, false, true, pt(cx + rx, cy));
        p.close();
        Some(p)
    }

    /// The path of a `line` element.
    pub fn line(x1: f64, y1: f64, x2: f64, y2: f64) -> Path {
        let mut p = Path::new();
        p.move_to(Point::new(x1, y1));
        p.line_to(Point::new(x2, y2));
        p
    }

    /// The path of a `polyline` / `polygon` from its coordinate list, or
    /// `None` when there are no points. An odd trailing number is dropped.
    pub fn poly(coords: &[f64], closed: bool) -> Option<Path> {
        let n = coords.len() / 2;
        if n == 0 {
            return None;
        }
        let mut p = Path::new();
        for i in 0..n {
            let pt = Point::new(coords[2 * i], coords[2 * i + 1]);
            if i == 0 {
                p.move_to(pt);
            } else {
                p.line_to(pt);
            }
        }
        if closed {
            p.close();
        }
        Some(p)
    }
}

struct Scanner<'a> {
    b: &'a [u8],
    s: &'a str,
    i: usize,
}

impl Scanner<'_> {
    fn peek(&self) -> Option<u8> {
        self.b.get(self.i).copied()
    }

    fn skip_sep(&mut self) {
        while let Some(c) = self.peek() {
            if c == b',' || c.is_ascii_whitespace() {
                self.i += 1;
            } else {
                break;
            }
        }
    }

    fn number(&mut self) -> Option<f64> {
        self.skip_sep();
        let (v, n) = parse_number(&self.s[self.i..])?;
        self.i += n;
        Some(v)
    }

    fn numbers<const N: usize>(&mut self) -> Option<[f64; N]> {
        let mut out = [0.0; N];
        for o in out.iter_mut() {
            *o = self.number()?;
        }
        Some(out)
    }

    fn flag(&mut self) -> Option<bool> {
        self.skip_sep();
        let v = match self.peek()? {
            b'0' => false,
            b'1' => true,
            _ => return None,
        };
        self.i += 1;
        Some(v)
    }
}

/// A flattened subpath: a polyline and whether it was closed with `Z`.
#[derive(Clone, Debug, PartialEq)]
pub struct Subpath {
    /// The polyline vertices.
    pub points: Vec<Point>,
    /// Whether the subpath ended with `Z`.
    pub closed: bool,
}

/// Number of equal parameter steps needed to flatten a cubic within `tol`.
fn cubic_steps(p0: Point, p1: Point, p2: Point, p3: Point, tol: f64) -> usize {
    let d1 = (p0.x - 2.0 * p1.x + p2.x).powi(2) + (p0.y - 2.0 * p1.y + p2.y).powi(2);
    let d2 = (p1.x - 2.0 * p2.x + p3.x).powi(2) + (p1.y - 2.0 * p2.y + p3.y).powi(2);
    let m = d1.max(d2);
    let n = (0.75 * m.sqrt() / tol).sqrt().ceil();
    if n.is_finite() {
        (n as usize).clamp(1, 1000)
    } else {
        1
    }
}

/// Flattens `path` into polylines. Every point is first transformed by `m`;
/// curves are subdivided so that they lie within `tol` (in the transformed
/// space) of the result.
///
/// A subpath is a run of commands beginning at a `MoveTo`. A lone `MoveTo`
/// with no drawing command produces no subpath; `M x y Z` produces a
/// one-point closed subpath.
pub fn flatten(path: &Path, m: &Matrix, tol: f64) -> Vec<Subpath> {
    let mut out: Vec<Subpath> = Vec::new();
    let mut cur: Option<Subpath> = None;
    let mut last = Point::default();
    for seg in &path.segments {
        match *seg {
            Segment::MoveTo(p) => {
                if let Some(s) = cur.take() {
                    if s.points.len() > 1 {
                        out.push(s);
                    }
                }
                let p = m.apply(p);
                last = p;
                cur = Some(Subpath { points: vec![p], closed: false });
            }
            Segment::LineTo(p) => {
                let p = m.apply(p);
                if let Some(s) = cur.as_mut() {
                    s.points.push(p);
                }
                last = p;
            }
            Segment::CubicTo(c1, c2, p) => {
                let (c1, c2, p) = (m.apply(c1), m.apply(c2), m.apply(p));
                if let Some(s) = cur.as_mut() {
                    let n = cubic_steps(last, c1, c2, p, tol);
                    for i in 1..=n {
                        if i == n {
                            s.points.push(p);
                        } else {
                            let t = i as f64 / n as f64;
                            let u = 1.0 - t;
                            let (b0, b1, b2, b3) = (u * u * u, 3.0 * u * u * t, 3.0 * u * t * t, t * t * t);
                            s.points.push(Point::new(
                                b0 * last.x + b1 * c1.x + b2 * c2.x + b3 * p.x,
                                b0 * last.y + b1 * c1.y + b2 * c2.y + b3 * p.y,
                            ));
                        }
                    }
                }
                last = p;
            }
            Segment::Close => {
                if let Some(mut s) = cur.take() {
                    s.closed = true;
                    out.push(s);
                }
            }
        }
    }
    if let Some(s) = cur.take() {
        if s.points.len() > 1 {
            out.push(s);
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn flat(d: &str) -> Vec<Subpath> {
        flatten(&Path::parse(d), &Matrix::IDENTITY, 0.01)
    }

    #[test]
    fn lines_and_relative_commands() {
        let p = flat("M10 10 h5 v5 l-5 0 z");
        assert_eq!(p.len(), 1);
        assert!(p[0].closed);
        assert_eq!(p[0].points.len(), 4);
        assert_eq!(p[0].points[2], Point::new(15.0, 15.0));
    }

    #[test]
    fn implicit_lineto_after_moveto() {
        let p = flat("M0 0 10 0 10 10");
        assert_eq!(p[0].points.len(), 3);
    }

    #[test]
    fn stops_at_bad_token_keeping_earlier_commands() {
        let p = flat("M0 0 L10 0 L10 x L20 20");
        assert_eq!(p[0].points.len(), 2);
        let p = flat("M0 0 L10 0 z 5 5");
        assert_eq!(p[0].points.len(), 2);
        assert!(p[0].closed);
    }

    #[test]
    fn arc_flags_without_separators() {
        let path = Path::parse("M0 0 a5 5 0 0110 10");
        assert_eq!(path.current(), Point::new(10.0, 10.0));
    }

    #[test]
    fn lone_moveto_is_not_a_subpath_but_move_close_is() {
        assert!(flat("M5 5").is_empty());
        let p = flat("M5 5 Z");
        assert_eq!(p.len(), 1);
        assert!(p[0].closed);
    }

    #[test]
    fn drawing_after_close_starts_at_subpath_start() {
        let p = flat("M0 0 L10 0 L10 10 Z L5 5");
        assert_eq!(p.len(), 2);
        assert_eq!(p[1].points[0], Point::new(0.0, 0.0));
    }

    #[test]
    fn quadratic_equals_cubic() {
        let a = Path::parse("M0 0 Q10 10 20 0");
        match a.segments[1] {
            Segment::CubicTo(c1, c2, e) => {
                assert!((c1.x - 20.0 / 3.0).abs() < 1e-12 && (c1.y - 20.0 / 3.0).abs() < 1e-12);
                assert!((c2.x - 40.0 / 3.0).abs() < 1e-12);
                assert_eq!(e, Point::new(20.0, 0.0));
            }
            _ => panic!(),
        }
    }

    #[test]
    fn smooth_commands_reflect() {
        let a = Path::parse("M0 0 C0 10 10 10 10 0 S20 -10 20 0");
        match a.segments[2] {
            Segment::CubicTo(c1, _, _) => assert_eq!(c1, Point::new(10.0, -10.0)),
            _ => panic!(),
        }
    }

    #[test]
    fn circle_flattening_stays_on_circle() {
        let p = Path::ellipse(0.0, 0.0, 50.0, 50.0).unwrap();
        for sp in flatten(&p, &Matrix::IDENTITY, 0.01) {
            for q in &sp.points {
                let r = (q.x * q.x + q.y * q.y).sqrt();
                assert!((r - 50.0).abs() < 0.02, "r = {r}");
            }
        }
    }

    #[test]
    fn rect_rules() {
        assert!(Path::rect(0.0, 0.0, 0.0, 5.0, None, None).is_none());
        let p = Path::rect(0.0, 0.0, 10.0, 10.0, Some(20.0), None).unwrap();
        assert!(p.segments.len() > 6);
        let p = Path::rect(0.0, 0.0, 10.0, 10.0, Some(-1.0), None).unwrap();
        assert_eq!(p.segments.len(), 5);
    }

    #[test]
    fn poly_drops_odd_number() {
        let p = Path::poly(&[0.0, 0.0, 1.0, 1.0, 2.0], true).unwrap();
        assert_eq!(p.segments.len(), 3);
        assert!(Path::poly(&[1.0], false).is_none());
    }
}
