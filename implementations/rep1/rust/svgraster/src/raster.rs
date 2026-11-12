//! Active-edge-table scan converter with sub-scanline sampling.
//!
//! Each pixel row is divided into [`SUBSAMPLES`] equally spaced
//! sub-scanlines. Every sub-scanline is intersected exactly with the polygon
//! edges, the crossings are sorted and walked to produce `x` spans according
//! to the fill rule, and the spans are accumulated into per-pixel coverage.

use crate::geom::Point;

/// Number of sub-scanlines per pixel row.
pub const SUBSAMPLES: usize = 64;

/// How the inside of a polygon set is determined.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub enum FillRule {
    /// Inside when the winding number is non-zero.
    #[default]
    NonZero,
    /// Inside when the crossing count is odd.
    EvenOdd,
}

#[derive(Clone, Copy)]
struct Edge {
    x0: f64,
    y0: f64,
    y1: f64,
    slope: f64,
    dir: i32,
    x: f64,
}

/// Scan-converts the closed polygons `polys` (device coordinates) on a
/// `width x height` pixel grid. For every pixel row with any coverage,
/// `emit(row, x0, coverage)` is called, where `coverage[k]` is the covered
/// fraction of pixel `(x0 + k, row)`.
///
/// Edges are sorted once; only sub-scanlines with active edges are visited
/// and the active set is kept in `x` order incrementally, so the cost is
/// `O(E log E + sum of active edges + touched pixels)`.
pub fn scan<F>(polys: &[Vec<Point>], rule: FillRule, width: usize, height: usize, mut emit: F)
where
    F: FnMut(usize, usize, &[f64]),
{
    let mut edges: Vec<Edge> = Vec::new();
    for poly in polys {
        let n = poly.len();
        if n < 2 {
            continue;
        }
        for i in 0..n {
            let (a, b) = (poly[i], poly[(i + 1) % n]);
            if !(a.x.is_finite() && a.y.is_finite() && b.x.is_finite() && b.y.is_finite()) || a.y == b.y {
                continue;
            }
            let (top, bot, dir) = if a.y < b.y { (a, b, 1) } else { (b, a, -1) };
            edges.push(Edge {
                x0: top.x,
                y0: top.y,
                y1: bot.y,
                slope: (bot.x - top.x) / (bot.y - top.y),
                dir,
                x: top.x,
            });
        }
    }
    if edges.is_empty() || width == 0 || height == 0 {
        return;
    }
    edges.sort_by(|a, b| a.y0.total_cmp(&b.y0));
    let ymax = edges.iter().fold(f64::NEG_INFINITY, |m, e| m.max(e.y1));
    let w = width as f64;
    let last_row = ((ymax.floor().min(height as f64 - 1.0)).max(-1.0)) as i64;

    let mut active: Vec<Edge> = Vec::new();
    let mut next = 0usize;
    let mut acc = vec![0.0f64; width + 2];
    let mut delta = vec![0.0f64; width + 2];
    let mut cov: Vec<f64> = Vec::new();

    let mut row = edges[0].y0.floor().max(0.0) as i64;
    while row <= last_row {
        let row_end = (row + 1) as f64;
        // Skip rows with nothing active and nothing starting in them.
        if active.is_empty() {
            if next >= edges.len() {
                break;
            }
            if edges[next].y0 >= row_end {
                row = edges[next].y0.floor() as i64;
                continue;
            }
        }
        let mut min_x = usize::MAX;
        let mut max_x = 0usize;
        for k in 0..SUBSAMPLES {
            let y = row as f64 + (k as f64 + 0.5) / SUBSAMPLES as f64;
            while next < edges.len() && edges[next].y0 <= y {
                active.push(edges[next]);
                next += 1;
            }
            active.retain(|e| e.y1 > y);
            if active.is_empty() {
                continue;
            }
            for e in active.iter_mut() {
                e.x = e.x0 + (y - e.y0) * e.slope;
            }
            // Insertion sort: the active set is nearly sorted from the
            // previous sub-scanline.
            for i in 1..active.len() {
                let mut j = i;
                while j > 0 && active[j - 1].x > active[j].x {
                    active.swap(j - 1, j);
                    j -= 1;
                }
            }
            let mut wind = 0i32;
            let mut span_start = 0.0;
            for e in active.iter() {
                let was_inside = inside(wind, rule);
                wind += e.dir;
                let now_inside = inside(wind, rule);
                if !was_inside && now_inside {
                    span_start = e.x;
                } else if was_inside && !now_inside {
                    let x0 = span_start.clamp(0.0, w);
                    let x1 = e.x.clamp(0.0, w);
                    if x1 > x0 {
                        add_span(&mut acc, &mut delta, x0, x1, &mut min_x, &mut max_x);
                    }
                }
            }
        }
        if min_x <= max_x && row >= 0 {
            let hi = max_x.min(width - 1);
            if min_x <= hi {
                cov.clear();
                let mut run = 0.0;
                for i in min_x..=hi {
                    run += delta[i];
                    cov.push(((acc[i] + run) / SUBSAMPLES as f64).clamp(0.0, 1.0));
                }
                emit(row as usize, min_x, &cov);
            }
            for i in min_x..=max_x.min(width + 1) {
                acc[i] = 0.0;
                delta[i] = 0.0;
            }
            // delta may be written one past max_x.
            delta[(max_x + 1).min(width + 1)] = 0.0;
            acc[(max_x + 1).min(width + 1)] = 0.0;
        }
        row += 1;
    }
}

fn inside(wind: i32, rule: FillRule) -> bool {
    match rule {
        FillRule::NonZero => wind != 0,
        FillRule::EvenOdd => wind & 1 != 0,
    }
}

/// Adds the span `[x0, x1)` (already clipped to the canvas) to the row
/// accumulators in O(1): partial pixels go to `acc`, whole pixels in between
/// to the difference array `delta`.
fn add_span(acc: &mut [f64], delta: &mut [f64], x0: f64, x1: f64, min_x: &mut usize, max_x: &mut usize) {
    let i0 = x0 as usize;
    let i1 = x1 as usize;
    if i0 == i1 {
        acc[i0] += x1 - x0;
    } else {
        acc[i0] += (i0 + 1) as f64 - x0;
        acc[i1] += x1 - i1 as f64;
        delta[i0 + 1] += 1.0;
        delta[i1] -= 1.0;
    }
    *min_x = (*min_x).min(i0);
    *max_x = (*max_x).max(i1);
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rect(x0: f64, y0: f64, x1: f64, y1: f64) -> Vec<Point> {
        vec![Point::new(x0, y0), Point::new(x1, y0), Point::new(x1, y1), Point::new(x0, y1)]
    }

    fn coverage_grid(polys: &[Vec<Point>], rule: FillRule, w: usize, h: usize) -> Vec<Vec<f64>> {
        let mut g = vec![vec![0.0; w]; h];
        scan(polys, rule, w, h, |row, x0, cov| {
            for (k, c) in cov.iter().enumerate() {
                g[row][x0 + k] = *c;
            }
        });
        g
    }

    #[test]
    fn fractional_edge_has_half_coverage() {
        let g = coverage_grid(&[rect(1.0, 1.0, 4.5, 3.0)], FillRule::NonZero, 8, 4);
        assert_eq!(g[1][0], 0.0);
        assert_eq!(g[1][1], 1.0);
        assert_eq!(g[1][3], 1.0);
        assert!((g[1][4] - 0.5).abs() < 1e-12);
        assert_eq!(g[1][5], 0.0);
        assert_eq!(g[0][2], 0.0);
        assert_eq!(g[3][2], 0.0);
    }

    #[test]
    fn evenodd_leaves_hole_and_nonzero_fills_it() {
        let polys = vec![rect(0.0, 0.0, 8.0, 8.0), rect(2.0, 2.0, 6.0, 6.0)];
        let eo = coverage_grid(&polys, FillRule::EvenOdd, 8, 8);
        let nz = coverage_grid(&polys, FillRule::NonZero, 8, 8);
        assert_eq!(eo[4][4], 0.0);
        assert_eq!(nz[4][4], 1.0);
        assert_eq!(eo[1][1], 1.0);
    }

    #[test]
    fn opposite_winding_cancels_under_nonzero() {
        let mut inner = rect(2.0, 2.0, 6.0, 6.0);
        inner.reverse();
        let g = coverage_grid(&[rect(0.0, 0.0, 8.0, 8.0), inner], FillRule::NonZero, 8, 8);
        assert_eq!(g[4][4], 0.0);
    }

    #[test]
    fn clips_to_canvas() {
        let g = coverage_grid(&[rect(-10.0, -10.0, 100.0, 100.0)], FillRule::NonZero, 4, 4);
        assert!(g.iter().flatten().all(|&c| c == 1.0));
    }

    #[test]
    fn triangle_area_is_close() {
        let tri = vec![Point::new(0.0, 0.0), Point::new(16.0, 0.0), Point::new(0.0, 16.0)];
        let g = coverage_grid(&[tri], FillRule::NonZero, 16, 16);
        let total: f64 = g.iter().flatten().sum();
        assert!((total - 128.0).abs() < 0.2, "{total}");
    }
}
