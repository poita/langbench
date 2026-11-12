//! Total-fit line breaking over a [`HList`].

use crate::hlist::{HList, Item};

/// The parameters of the demerit formula and the two passes.
#[derive(Clone, Copy, Debug)]
pub struct BreakParams {
    pub tolerance: i64,
    pub line_penalty: i64,
    pub adj_demerits: i64,
    pub double_hyphen_demerits: i64,
    pub final_hyphen_demerits: i64,
}

/// The outcome of breaking one list.
#[derive(Clone, Debug)]
pub struct Breaking {
    /// Breakpoint numbers (indices into `HList::bps`) that end each line.
    pub breaks: Vec<usize>,
    /// Total demerits of the chosen path.
    pub total: i64,
    /// `true` when pass 1 failed and pass 2 was needed.
    pub emergency: bool,
}

const TIGHT: i64 = 0;
const DECENT: i64 = 1;
const LOOSE: i64 = 2;
const VERY_LOOSE: i64 = 3;

/// How a candidate line fits.
enum Fit {
    /// Normal line: badness and fitness class.
    Ok(i64, i64),
    Unstretchable,
    Overfull,
}

fn badness_of(d: i64, y: i64, z: i64, infinite: bool) -> Fit {
    if d >= 0 && infinite {
        return Fit::Ok(0, DECENT);
    }
    if d == 0 {
        return Fit::Ok(0, DECENT);
    }
    if d > 0 {
        if y == 0 {
            return Fit::Unstretchable;
        }
        let (d, y) = (d as i128, y as i128);
        let b = ((100 * d * d * d) / (y * y * y)).min(10000) as i64;
        let class = if d > y {
            VERY_LOOSE
        } else if 2 * d > y {
            LOOSE
        } else {
            DECENT
        };
        Fit::Ok(b, class)
    } else {
        let e = -d;
        if z == 0 || e > z {
            return Fit::Overfull;
        }
        let (e, z) = (e as i128, z as i128);
        let b = ((100 * e * e * e) / (z * z * z)).min(10000) as i64;
        let class = if 2 * e > z { TIGHT } else { DECENT };
        Fit::Ok(b, class)
    }
}

struct Node {
    bp: usize,
    class: i64,
    total: i64,
    prev: usize,
}

/// Breaks `list` into lines. The first line has width `measure -
/// first_indent`, every other line `measure`.
pub fn break_lines(list: &HList, measure: i64, first_indent: i64, params: &BreakParams) -> Breaking {
    if let Some((breaks, total)) = run_pass(list, measure, first_indent, params, true) {
        return Breaking { breaks, total, emergency: false };
    }
    let (breaks, total) = run_pass(list, measure, first_indent, params, false).expect("pass 2 always succeeds");
    Breaking { breaks, total, emergency: true }
}

fn run_pass(
    list: &HList,
    measure: i64,
    first_indent: i64,
    params: &BreakParams,
    pass1: bool,
) -> Option<(Vec<usize>, i64)> {
    let nbp = list.bps.len();
    let last = nbp - 1;
    let flagged = |bi: usize| matches!(&list.items[list.bps[bi]], Item::Penalty { flagged: true, .. });
    let penalty = |bi: usize| match &list.items[list.bps[bi]] {
        Item::Penalty { p, .. } => *p,
        _ => 0,
    };

    let mut nodes: Vec<Node> = vec![Node { bp: 0, class: DECENT, total: 0, prev: usize::MAX }];
    let mut active: Vec<usize> = vec![0];

    for bi in 1..nbp {
        let p = penalty(bi);
        let fl = flagged(bi);
        let mut best: [Option<(i64, usize)>; 4] = [None; 4];
        let mut survivors: Vec<usize> = Vec::new();
        let cand: &[usize] = if pass1 { &active } else { &[] };
        let all_nodes = nodes.len();
        let visit = |n: usize, best: &mut [Option<(i64, usize)>; 4], nodes: &Vec<Node>| -> bool {
            let node = &nodes[n];
            let measure_l = if node.bp == 0 { measure - first_indent } else { measure };
            let ls = list.line(node.bp, bi);
            if pass1 && ls.w_no_pre - ls.z > measure_l {
                return false; // overfull for good: leaves the active set
            }
            let (b, c) = match badness_of(measure_l - ls.w, ls.y, ls.z, ls.infinite) {
                Fit::Ok(b, c) => (b, c),
                Fit::Unstretchable => {
                    if pass1 {
                        return true;
                    }
                    (10000, VERY_LOOSE)
                }
                Fit::Overfull => {
                    if pass1 {
                        return true;
                    }
                    (10000, TIGHT)
                }
            };
            if pass1 && b > params.tolerance {
                return true;
            }
            let mut dem = (params.line_penalty + b) * (params.line_penalty + b);
            if (0..10000).contains(&p) {
                dem += p * p;
            } else if p > -10000 && p < 0 {
                dem -= p * p;
            }
            let flag0 = node.bp != 0 && flagged(node.bp);
            if fl && flag0 {
                dem += params.double_hyphen_demerits;
            }
            if (c - node.class).abs() > 1 {
                dem += params.adj_demerits;
            }
            if bi == last && flag0 {
                dem += params.final_hyphen_demerits;
            }
            let total = node.total + dem;
            let slot = &mut best[c as usize];
            match slot {
                Some((t, _)) if *t <= total => {}
                _ => *slot = Some((total, n)),
            }
            true
        };
        if pass1 {
            for &n in cand {
                if visit(n, &mut best, &nodes) {
                    survivors.push(n);
                }
            }
        } else {
            for n in 0..all_nodes {
                visit(n, &mut best, &nodes);
            }
        }
        for (c, b) in best.iter().enumerate() {
            if let Some((total, prev)) = b {
                nodes.push(Node { bp: bi, class: c as i64, total: *total, prev: *prev });
                survivors.push(nodes.len() - 1);
            }
        }
        if pass1 {
            active = survivors;
            if active.is_empty() && bi < last {
                return None;
            }
        }
    }

    let mut best: Option<usize> = None;
    for (n, node) in nodes.iter().enumerate() {
        if node.bp == last {
            match best {
                Some(b) if nodes[b].total <= node.total => {}
                _ => best = Some(n),
            }
        }
    }
    let best = best?;
    let total = nodes[best].total;
    let mut breaks = Vec::new();
    let mut n = best;
    while n != 0 {
        breaks.push(nodes[n].bp);
        n = nodes[n].prev;
    }
    breaks.reverse();
    Some((breaks, total))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn badness_examples_from_spec() {
        // L = 142000
        let fit = |w: i64, y: i64, z: i64| badness_of(142000 - w, y, z, false);
        assert!(matches!(fit(142000, 1270, 850), Fit::Ok(0, DECENT)));
        assert!(matches!(fit(130980, 6350, 4250), Fit::Ok(522, VERY_LOOSE)));
        assert!(matches!(fit(145890, 7620, 5100), Fit::Ok(44, TIGHT)));
        assert!(matches!(fit(111050, 5080, 3400), Fit::Ok(10000, VERY_LOOSE)));
        assert!(matches!(fit(164800, 8890, 5950), Fit::Overfull));
        assert!(matches!(fit(15630, 0, 0), Fit::Unstretchable));
    }

    #[test]
    fn infinite_glue_excuses_short_lines_only() {
        assert!(matches!(badness_of(500, 0, 0, true), Fit::Ok(0, DECENT)));
        assert!(matches!(badness_of(-500, 0, 0, true), Fit::Overfull));
    }
}

#[cfg(test)]
mod break_tests {
    use super::*;
    use crate::env::Env;
    use crate::hlist::{build_list, push_text, BuildOpts, StyleState};
    use crate::metrics::Family;
    use crate::settings::Settings;

    fn params() -> BreakParams {
        BreakParams {
            tolerance: 1000,
            line_penalty: 10,
            adj_demerits: 10000,
            double_hyphen_demerits: 10000,
            final_hyphen_demerits: 5000,
        }
    }

    fn list(text: &str) -> HList {
        let dir = std::path::Path::new(concat!(env!("CARGO_MANIFEST_DIR"), "/data"));
        let env = Env::load(Settings::default(), dir).unwrap();
        let mut units = Vec::new();
        push_text(&mut units, text, StyleState::plain(Family::Serif, 10000).st());
        build_list(&env, Vec::new(), units, BuildOpts { ragged: false, hyphenate: true })
    }

    #[test]
    fn spec_example_six_breaks_after_the() {
        let l = list("The quick brown fox jumps over the lazy dog.");
        let b = break_lines(&l, 142000, 0, &params());
        assert!(!b.emergency);
        assert_eq!(b.total, 3016);
        assert_eq!(b.breaks.len(), 2);
    }

    #[test]
    fn narrow_measure_falls_back_to_pass_two() {
        let l = list("extraordinarily incomprehensible");
        let b = break_lines(&l, 10000, 0, &params());
        assert!(b.emergency);
        assert!(!b.breaks.is_empty());
    }

    #[test]
    fn empty_list_is_one_line() {
        let l = list("");
        let b = break_lines(&l, 100000, 0, &params());
        assert_eq!(b.breaks.len(), 1);
        assert_eq!(b.total, 100);
    }
}
