//! Stroke outlining: turns flattened centrelines into a set of polygons
//! whose nonzero-rule union is the stroked region.

use crate::geom::Point;
use crate::path::Subpath;
use std::f64::consts::PI;

/// Line end style.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub enum LineCap {
    /// Flat end at the endpoint.
    #[default]
    Butt,
    /// Half disc beyond the endpoint.
    Round,
    /// Half square beyond the endpoint.
    Square,
}

/// Corner style.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub enum LineJoin {
    /// Sharp corner, subject to the miter limit.
    #[default]
    Miter,
    /// Circular arc.
    Round,
    /// Flat cut.
    Bevel,
}

/// Parameters of a stroke.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct StrokeStyle {
    /// Stroke width in the coordinate system of the input points.
    pub width: f64,
    /// End style.
    pub cap: LineCap,
    /// Corner style.
    pub join: LineJoin,
    /// Miter limit (values below 1 are treated as 1).
    pub miter_limit: f64,
}

fn sub(a: Point, b: Point) -> Point {
    Point::new(a.x - b.x, a.y - b.y)
}
fn add_scaled(p: Point, d: Point, k: f64) -> Point {
    Point::new(p.x + d.x * k, p.y + d.y * k)
}
fn unit(v: Point) -> Point {
    let l = v.x.hypot(v.y);
    Point::new(v.x / l, v.y / l)
}

/// Signed area (shoelace) of a polygon.
fn signed_area(p: &[Point]) -> f64 {
    let mut a = 0.0;
    for i in 0..p.len() {
        let q = p[(i + 1) % p.len()];
        a += p[i].x * q.y - q.x * p[i].y;
    }
    a / 2.0
}

fn push_oriented(out: &mut Vec<Vec<Point>>, mut poly: Vec<Point>) {
    if signed_area(&poly) < 0.0 {
        poly.reverse();
    }
    out.push(poly);
}

/// Points along the circle of radius `r` about `c`, from angle `a0` sweeping
/// by `sweep` radians, both ends included.
fn arc_points(c: Point, r: f64, a0: f64, sweep: f64, tol: f64, out: &mut Vec<Point>) {
    let step = if tol >= r { PI / 2.0 } else { 2.0 * (1.0 - tol / r).acos() };
    let n = ((sweep.abs() / step).ceil() as usize).clamp(1, 100_000);
    for i in 0..=n {
        let a = a0 + sweep * i as f64 / n as f64;
        out.push(Point::new(c.x + r * a.cos(), c.y + r * a.sin()));
    }
}

/// Builds the outline pieces for all `subpaths`. Every returned polygon has
/// positive signed area. `tol` is the flattening tolerance for round joins
/// and caps, in the same units as the input points.
pub fn outline(subpaths: &[Subpath], style: &StrokeStyle, tol: f64) -> Vec<Vec<Point>> {
    let mut out = Vec::new();
    let r = style.width / 2.0;
    let miter_limit = style.miter_limit.max(1.0);
    for sp in subpaths {
        let mut pts: Vec<Point> = Vec::with_capacity(sp.points.len());
        for &p in &sp.points {
            if pts.last() != Some(&p) {
                pts.push(p);
            }
        }
        if sp.closed && pts.len() > 1 && pts.last() == pts.first() {
            pts.pop();
        }
        let n = pts.len();
        if n == 0 {
            continue;
        }
        if n == 1 {
            let p = pts[0];
            match style.cap {
                LineCap::Butt => {}
                LineCap::Round => {
                    let mut poly = Vec::new();
                    arc_points(p, r, 0.0, 2.0 * PI, tol, &mut poly);
                    poly.pop();
                    push_oriented(&mut out, poly);
                }
                LineCap::Square => push_oriented(
                    &mut out,
                    vec![
                        Point::new(p.x - r, p.y - r),
                        Point::new(p.x + r, p.y - r),
                        Point::new(p.x + r, p.y + r),
                        Point::new(p.x - r, p.y + r),
                    ],
                ),
            }
            continue;
        }
        let nseg = if sp.closed { n } else { n - 1 };
        let seg = |i: usize| (pts[i], pts[(i + 1) % n]);
        // Segment bodies.
        for i in 0..nseg {
            let (a, b) = seg(i);
            let d = unit(sub(b, a));
            let nn = Point::new(-d.y * r, d.x * r);
            push_oriented(
                &mut out,
                vec![
                    Point::new(a.x + nn.x, a.y + nn.y),
                    Point::new(b.x + nn.x, b.y + nn.y),
                    Point::new(b.x - nn.x, b.y - nn.y),
                    Point::new(a.x - nn.x, a.y - nn.y),
                ],
            );
        }
        // Joins.
        let joints: Vec<usize> = if sp.closed { (0..n).collect() } else { (1..n - 1).collect() };
        for i in joints {
            let p = pts[i];
            let d0 = unit(sub(p, pts[(i + n - 1) % n]));
            let d1 = unit(sub(pts[(i + 1) % n], p));
            let cross = d0.x * d1.y - d0.y * d1.x;
            let dot = d0.x * d1.x + d0.y * d1.y;
            if cross == 0.0 && dot > 0.0 {
                continue;
            }
            let s = if cross > 0.0 { 1.0 } else { -1.0 };
            let na = Point::new(s * d0.y, -s * d0.x);
            let nb = Point::new(s * d1.y, -s * d1.x);
            let a = add_scaled(p, na, r);
            let b = add_scaled(p, nb, r);
            match style.join {
                LineJoin::Round => {
                    let sweep = if cross == 0.0 {
                        s * PI
                    } else {
                        (na.x * nb.y - na.y * nb.x).atan2(na.x * nb.x + na.y * nb.y)
                    };
                    let mut poly = vec![p];
                    arc_points(p, r, na.y.atan2(na.x), sweep, tol, &mut poly);
                    push_oriented(&mut out, poly);
                }
                LineJoin::Miter => {
                    let ratio = 1.0 / ((1.0 + dot) / 2.0).sqrt();
                    if dot > -1.0 && cross != 0.0 && ratio <= miter_limit {
                        let k = r / (1.0 + dot);
                        let m = Point::new(p.x + (na.x + nb.x) * k, p.y + (na.y + nb.y) * k);
                        push_oriented(&mut out, vec![p, a, m, b]);
                    } else {
                        push_oriented(&mut out, vec![p, a, b]);
                    }
                }
                LineJoin::Bevel => push_oriented(&mut out, vec![p, a, b]),
            }
        }
        // Caps.
        if !sp.closed && style.cap != LineCap::Butt {
            let ends = [(pts[0], unit(sub(pts[0], pts[1]))), (pts[n - 1], unit(sub(pts[n - 1], pts[n - 2])))];
            for (p, u) in ends {
                let nn = Point::new(-u.y * r, u.x * r);
                match style.cap {
                    LineCap::Square => push_oriented(
                        &mut out,
                        vec![
                            Point::new(p.x + nn.x, p.y + nn.y),
                            Point::new(p.x + nn.x + u.x * r, p.y + nn.y + u.y * r),
                            Point::new(p.x - nn.x + u.x * r, p.y - nn.y + u.y * r),
                            Point::new(p.x - nn.x, p.y - nn.y),
                        ],
                    ),
                    LineCap::Round => {
                        let mut poly = Vec::new();
                        arc_points(p, r, nn.y.atan2(nn.x), -PI, tol, &mut poly);
                        push_oriented(&mut out, poly);
                    }
                    LineCap::Butt => {}
                }
            }
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn style(cap: LineCap, join: LineJoin) -> StrokeStyle {
        StrokeStyle { width: 2.0, cap, join, miter_limit: 4.0 }
    }

    fn line(pts: &[(f64, f64)], closed: bool) -> Subpath {
        Subpath { points: pts.iter().map(|&(x, y)| Point::new(x, y)).collect(), closed }
    }

    #[test]
    fn all_pieces_have_positive_area() {
        let sp = line(&[(0.0, 0.0), (10.0, 0.0), (10.0, 10.0), (0.0, 10.0)], true);
        for join in [LineJoin::Miter, LineJoin::Round, LineJoin::Bevel] {
            for poly in outline(&[sp.clone()], &style(LineCap::Round, join), 0.01) {
                assert!(signed_area(&poly) > 0.0);
            }
        }
    }

    #[test]
    fn butt_open_line_is_one_rectangle() {
        let sp = line(&[(0.0, 0.0), (10.0, 0.0)], false);
        let polys = outline(&[sp], &style(LineCap::Butt, LineJoin::Miter), 0.01);
        assert_eq!(polys.len(), 1);
        assert!((signed_area(&polys[0]) - 20.0).abs() < 1e-9);
    }

    #[test]
    fn square_cap_extends_by_half_width() {
        let sp = line(&[(0.0, 0.0), (10.0, 0.0)], false);
        let polys = outline(&[sp], &style(LineCap::Square, LineJoin::Miter), 0.01);
        let total: f64 = polys.iter().map(|p| signed_area(p)).sum();
        assert!((total - 24.0).abs() < 1e-9);
    }

    #[test]
    fn single_point_caps() {
        let sp = line(&[(5.0, 5.0), (5.0, 5.0)], false);
        assert!(outline(&[sp.clone()], &style(LineCap::Butt, LineJoin::Miter), 0.01).is_empty());
        let sq = outline(&[sp.clone()], &style(LineCap::Square, LineJoin::Miter), 0.01);
        assert!((signed_area(&sq[0]) - 4.0).abs() < 1e-9);
        let rd = outline(&[sp], &style(LineCap::Round, LineJoin::Miter), 0.001);
        assert!((signed_area(&rd[0]) - PI).abs() < 0.01);
    }

    #[test]
    fn miter_over_limit_falls_back_to_bevel() {
        // A very sharp corner: ratio far above 4.
        let sp = line(&[(0.0, 0.0), (10.0, 0.0), (0.0, 1.0)], false);
        let polys = outline(&[sp], &style(LineCap::Butt, LineJoin::Miter), 0.01);
        assert_eq!(polys.len(), 3);
        assert_eq!(polys[2].len(), 3);
    }
}
