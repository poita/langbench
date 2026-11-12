//! Setting broken lines: glue distribution, alignment, run merging and
//! vertical metrics.

use crate::env::Env;
use crate::hlist::{HList, Item};
use crate::linebreak::{break_lines, BreakParams};
use crate::metrics::FaceId;
use crate::settings::Align;
use crate::stats::Stats;
use crate::units::{fdiv, scale};

/// A positioned run of text (one `text` item of the output).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Run {
    pub text: String,
    pub face: FaceId,
    pub size: i64,
    pub raise: i64,
    pub x: i64,
    pub width: i64,
}

/// One set line: runs with absolute x coordinates and vertical metrics.
#[derive(Clone, Debug)]
pub struct PlacedLine {
    pub runs: Vec<Run>,
    pub ascent: i64,
    pub depth: i64,
    /// The x coordinate after the last item.
    pub x_end: i64,
    /// The line's set width.
    pub width: i64,
    /// Footnotes referenced by the line, in order.
    pub notes: Vec<usize>,
}

/// Where and how a list is set.
#[derive(Clone, Copy, Debug)]
pub struct ListSpec {
    pub align: Align,
    pub left: i64,
    pub measure: i64,
    pub first_indent: i64,
    /// Face and size used for the metrics of a line with no boxes.
    pub face: FaceId,
    pub size: i64,
}

/// Breaks a list and sets its lines, updating the statistics.
pub fn typeset_list(env: &Env, list: &HList, spec: &ListSpec, stats: &mut Stats) -> Vec<PlacedLine> {
    let s = &env.settings;
    let params = BreakParams {
        tolerance: s.tolerance,
        line_penalty: s.line_penalty,
        adj_demerits: s.adj_demerits,
        double_hyphen_demerits: s.double_hyphen_demerits,
        final_hyphen_demerits: s.final_hyphen_demerits,
    };
    let br = break_lines(list, spec.measure, spec.first_indent, &params);
    stats.total_demerits += br.total;
    if br.emergency {
        stats.emergency_lists += 1;
    }
    let mut lines = Vec::with_capacity(br.breaks.len());
    let mut a = 0;
    for &b in &br.breaks {
        let first = a == 0;
        let indent = if first { spec.first_indent } else { 0 };
        let l = spec.measure - indent;
        let line = set_line(env, list, a, b, l, spec.left + indent, spec);
        stats.lines += 1;
        if line.width > l {
            stats.overfull_lines += 1;
        }
        if matches!(&list.items[list.bps[b]], Item::Penalty { pre: Some(_), .. }) {
            stats.hyphenated_lines += 1;
        }
        lines.push(line);
        a = b;
    }
    lines
}

/// Sets the line between breakpoints `a` and `b` (breakpoint numbers).
fn set_line(env: &Env, list: &HList, a: usize, b: usize, l: i64, left_line: i64, spec: &ListSpec) -> PlacedLine {
    let s = list.first_item(a);
    let e = list.bps[b];
    let sums = list.line(a, b);
    let items = &list.items[s.min(e)..e];

    // Glue set widths.
    let mut widths: Vec<i64> = items
        .iter()
        .map(|it| match it {
            Item::Box(b) => b.width,
            Item::Rigid(w) => *w,
            Item::Glue { w, infinite, .. } => {
                if *infinite {
                    0
                } else {
                    *w
                }
            }
            Item::Penalty { .. } => 0,
        })
        .collect();
    if !sums.infinite && spec.align == Align::Justify {
        let big_e = l - sums.w;
        let glue = |f: &dyn Fn(i64, i64, i64) -> i64| -> Vec<(usize, i64)> {
            items
                .iter()
                .enumerate()
                .filter_map(|(i, it)| match it {
                    Item::Glue { w, y, z, .. } => Some((i, f(*w, *y, *z))),
                    _ => None,
                })
                .collect()
        };
        if big_e > 0 && sums.y > 0 {
            distribute(&mut widths, &glue(&|_, y, _| y), big_e, sums.y);
        } else if big_e < 0 && sums.z > 0 {
            if -big_e <= sums.z {
                distribute(&mut widths, &glue(&|_, _, z| z), big_e, sums.z);
            } else {
                for (i, it) in items.iter().enumerate() {
                    if let Item::Glue { w, z, .. } = it {
                        widths[i] = w - z;
                    }
                }
            }
        }
    }
    let pre = match &list.items[e] {
        Item::Penalty { pre: Some(p), .. } => Some(p),
        _ => None,
    };
    let w_set: i64 = widths.iter().sum::<i64>() + pre.map(|p| p.width).unwrap_or(0);
    let x0 = match spec.align {
        Align::Justify | Align::Left => left_line,
        Align::Right => left_line + l - w_set,
        Align::Center => left_line + fdiv(l - w_set, 2),
    };

    let mut runs: Vec<Run> = Vec::new();
    let mut notes = Vec::new();
    let mut ascent: Option<i64> = None;
    let mut depth: Option<i64> = None;
    let mut cur_frag: Option<u32> = None;
    let mut x = x0;

    let mut place = |bx: &crate::hlist::BoxItem, x: i64, cur_frag: &mut Option<u32>, runs: &mut Vec<Run>| {
        let f = env.fonts.face(bx.face);
        let asc = scale(f.ascent, bx.size) + bx.raise;
        let dep = (scale(f.descent, bx.size) - bx.raise).max(0);
        ascent = Some(ascent.map_or(asc, |a| a.max(asc)));
        depth = Some(depth.map_or(dep, |d| d.max(dep)));
        if *cur_frag == Some(bx.frag) {
            if let Some(last) = runs.last_mut() {
                if last.face == bx.face && last.size == bx.size && last.raise == bx.raise {
                    last.text.push_str(&bx.text);
                    last.width += bx.width;
                    return;
                }
            }
        }
        *cur_frag = Some(bx.frag);
        runs.push(Run { text: bx.text.clone(), face: bx.face, size: bx.size, raise: bx.raise, x, width: bx.width });
    };

    for (i, it) in items.iter().enumerate() {
        match it {
            Item::Box(bx) => {
                if let Some(n) = bx.note {
                    notes.push(n);
                }
                place(bx, x, &mut cur_frag, &mut runs);
            }
            Item::Rigid(_) | Item::Glue { .. } => cur_frag = None,
            Item::Penalty { .. } => {}
        }
        x += widths[i];
    }
    if let Some(p) = pre {
        place(p, x, &mut cur_frag, &mut runs);
        x += p.width;
    }

    let (ascent, depth) = match (ascent, depth) {
        (Some(a), Some(d)) => (a, d),
        _ => {
            let f = env.fonts.face(spec.face);
            (scale(f.ascent, spec.size), scale(f.descent, spec.size))
        }
    };
    PlacedLine { runs, ascent, depth, x_end: x, width: w_set, notes }
}

/// Distributes `total` over the weighted glues so the increments sum to it
/// exactly (floor division of cumulative products).
fn distribute(widths: &mut [i64], glues: &[(usize, i64)], total: i64, weight_sum: i64) {
    let mut p = 0;
    let mut prev = 0;
    for &(i, w) in glues {
        p += w;
        let c = fdiv(total * p, weight_sum);
        widths[i] += c - prev;
        prev = c;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn distribution_uses_floor_division() {
        // Example 4: six glues of 2540 shrinking by 3890 over shrinks of 850.
        let mut w = vec![2540; 6];
        let glues: Vec<(usize, i64)> = (0..6).map(|i| (i, 850)).collect();
        distribute(&mut w, &glues, -3890, 5100);
        assert_eq!(w, vec![1891, 1892, 1892, 1891, 1892, 1892]);
    }
}
