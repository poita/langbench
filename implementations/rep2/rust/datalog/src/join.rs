//! Execution of compiled join plans.

use crate::plan::{Access, Filter, Plan, Src, Version};
use crate::relation::{Relation, NONE};

use crate::parser::MAX_ARITY;

/// Half-open row ranges `(start, end)` visible to each version of a relation.
#[derive(Debug, Clone, Copy, Default)]
pub(crate) struct Delta {
    /// Rows `[0, start)` are old, `[start, end)` are the delta.
    pub start: u32,
    pub end: u32,
}

/// Run `plan` against `relations`, appending every derived head tuple that is
/// not yet in the head relation to `out` (flat, `arity` values per tuple).
///
/// `deltas[p]` gives the old/delta split of predicate `p`; it is only
/// consulted by steps whose version is `Old` or `Delta`.
pub(crate) fn run(
    plan: &Plan,
    relations: &[Relation],
    deltas: &[Delta],
    out: &mut Vec<u32>,
) {
    let ranges: Vec<(u32, u32)> = plan
        .steps
        .iter()
        .map(|s| match s.version {
            Version::Full => (0, relations[s.pred].len() as u32),
            Version::Old => (0, deltas[s.pred].start),
            Version::Delta => (deltas[s.pred].start, deltas[s.pred].end),
        })
        .collect();
    if ranges.iter().any(|&(lo, hi)| lo >= hi) {
        return;
    }
    let mut ctx = Ctx { plan, relations, ranges, binding: vec![0; plan.slots], out };
    if ctx.filters_pass(&plan.pre) {
        ctx.step(0);
    }
}

struct Ctx<'a> {
    plan: &'a Plan,
    relations: &'a [Relation],
    ranges: Vec<(u32, u32)>,
    binding: Vec<u32>,
    out: &'a mut Vec<u32>,
}

impl Ctx<'_> {
    #[inline]
    fn value(&self, s: Src) -> u32 {
        match s {
            Src::Const(c) => c,
            Src::Slot(i) => self.binding[i],
        }
    }

    fn filters_pass(&self, filters: &[Filter]) -> bool {
        filters.iter().all(|f| match f {
            Filter::Cmp { op, a, b } => op.holds(&self.value(*a), &self.value(*b)),
            Filter::Not { pred, key } => {
                let mut t = [0u32; MAX_ARITY];
                for (k, s) in key.iter().enumerate() {
                    t[k] = self.value(*s);
                }
                !self.relations[*pred].contains(&t[..key.len()])
            }
        })
    }

    fn emit(&mut self) {
        let mut t = [0u32; MAX_ARITY];
        let n = self.plan.head.len();
        for (k, s) in self.plan.head.iter().enumerate() {
            t[k] = self.value(*s);
        }
        if !self.relations[self.plan.head_pred].contains(&t[..n]) {
            self.out.extend_from_slice(&t[..n]);
        }
    }

    /// Try a candidate row of step `i`; recurse if it matches.
    #[inline]
    fn visit(&mut self, i: usize, row: &[u32]) {
        let plan = self.plan;
        let step = &plan.steps[i];
        for &(col, slot) in &step.binds {
            self.binding[slot] = row[col];
        }
        if step.checks.iter().all(|&(col, src)| row[col] == self.value(src))
            && self.filters_pass(&step.filters)
        {
            self.step(i + 1);
        }
    }

    fn step(&mut self, i: usize) {
        let plan = self.plan;
        let Some(step) = plan.steps.get(i) else {
            self.emit();
            return;
        };
        let relations = self.relations;
        let rel = &relations[step.pred];
        let (lo, hi) = self.ranges[i];
        match &step.access {
            Access::Scan => {
                for r in lo..hi {
                    self.visit(i, rel.row(r));
                }
            }
            Access::Probe { index } => {
                let mut key = [0u32; MAX_ARITY];
                for (k, s) in step.key.iter().enumerate() {
                    key[k] = self.value(*s);
                }
                let idx = rel.index(*index);
                let mut r = rel.probe(*index, &key[..step.key.len()]);
                while r != NONE && r < hi {
                    self.visit(i, rel.row(r));
                    r = idx.next(r);
                }
            }
            Access::Contains => {
                let mut key = [0u32; MAX_ARITY];
                for (k, s) in step.key.iter().enumerate() {
                    key[k] = self.value(*s);
                }
                if rel.find(&key[..step.key.len()]).is_some_and(|r| r < hi)
                    && self.filters_pass(&step.filters)
                {
                    self.step(i + 1);
                }
            }
        }
    }
}
