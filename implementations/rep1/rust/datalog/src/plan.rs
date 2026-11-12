//! Join plans: a rule compiled into an indexed nested-loop join.
//!
//! A [`Plan`] fixes, once per rule (and per delta position), the order in
//! which positive atoms are joined, which index each step probes, which
//! variables each step binds, and at which step each negated atom or
//! comparison is checked (as soon as its variables are bound).

use crate::ast::CmpOp;
use crate::relation::{Key, Relation, MAX_ARITY, NONE};

/// A value source: a constant or a variable slot.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Src {
    Const(u32),
    Var(usize),
}

/// An atom over interned constants and numbered variables.
#[derive(Debug, Clone)]
pub(crate) struct CAtom {
    pub(crate) pred: usize,
    pub(crate) terms: Vec<Src>,
}

/// A rule over interned constants and numbered variables.
#[derive(Debug, Clone)]
pub(crate) struct CRule {
    pub(crate) head: CAtom,
    pub(crate) pos: Vec<CAtom>,
    pub(crate) neg: Vec<CAtom>,
    pub(crate) cmps: Vec<(Src, CmpOp, Src)>,
    pub(crate) nvars: usize,
}

/// Which tuples of a relation a step may read in the current round.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Limit {
    /// Everything present at the start of the round.
    All,
    /// Only tuples that existed before the previous round's delta.
    Old,
    /// Only the previous round's new tuples.
    Delta,
}

#[derive(Debug, Clone)]
pub(crate) enum Access {
    /// Iterate the id range, checking `key` positions against constants.
    Scan,
    /// Probe index `n`.
    Index(usize),
    /// All positions bound: membership lookup.
    Point,
}

#[derive(Debug, Clone)]
pub(crate) enum Filter {
    Cmp(Src, CmpOp, Src),
    Neg(usize, Vec<Src>),
}

#[derive(Debug, Clone)]
pub(crate) struct Step {
    pred: usize,
    limit: Limit,
    access: Access,
    /// Bound positions (ascending) and where their values come from.
    key: Vec<(usize, Src)>,
    /// Positions whose values bind a fresh variable slot.
    binds: Vec<(usize, usize)>,
    /// Positions that must equal a slot bound earlier in the same atom.
    checks: Vec<(usize, usize)>,
    /// Filters that become evaluable after this step.
    filters: Vec<Filter>,
}

/// A compiled join plan for one rule variant.
#[derive(Debug, Clone)]
pub(crate) struct Plan {
    pub(crate) head_pred: usize,
    head: Vec<Src>,
    nvars: usize,
    pre: Vec<Filter>,
    steps: Vec<Step>,
}

fn vars_of(terms: &[Src]) -> impl Iterator<Item = usize> + '_ {
    terms.iter().filter_map(|t| if let Src::Var(v) = t { Some(*v) } else { None })
}

/// Compile `rule` into a plan.
///
/// `delta` is the body index (into `rule.pos`) of the atom read from the
/// previous round's delta, if any. `in_component[p]` tells whether predicate
/// `p` belongs to the component being evaluated: atoms of such predicates
/// before the delta atom read only old tuples, which makes each combination
/// of new tuples be derived exactly once.
///
/// Indexes needed by the plan are registered in `rels`.
pub(crate) fn build_plan(
    rule: &CRule,
    delta: Option<usize>,
    in_component: &[bool],
    rels: &mut [Relation],
) -> Plan {
    let mut bound = vec![false; rule.nvars];
    let mut remaining: Vec<usize> = (0..rule.pos.len()).collect();
    let mut pending_neg: Vec<usize> = (0..rule.neg.len()).collect();
    let mut pending_cmp: Vec<usize> = (0..rule.cmps.len()).collect();

    // Filters whose variables are all bound, removed from the pending lists.
    let mut take_filters = |bound: &[bool]| -> Vec<Filter> {
        let is_bound = |s: &Src| match s {
            Src::Const(_) => true,
            Src::Var(v) => bound[*v],
        };
        let mut out = Vec::new();
        pending_cmp.retain(|&i| {
            let (l, op, r) = rule.cmps[i];
            if is_bound(&l) && is_bound(&r) {
                out.push(Filter::Cmp(l, op, r));
                false
            } else {
                true
            }
        });
        pending_neg.retain(|&i| {
            let a = &rule.neg[i];
            if a.terms.iter().all(is_bound) {
                out.push(Filter::Neg(a.pred, a.terms.clone()));
                false
            } else {
                true
            }
        });
        out
    };

    let pre = take_filters(&bound);
    let mut steps = Vec::new();
    let mut first = delta;
    while !remaining.is_empty() {
        // Delta atom first, then the atom with the most bound arguments;
        // ties go to the earliest in the body.
        let pick = match first.take() {
            Some(d) => d,
            None => {
                let score = |i: usize| {
                    rule.pos[i]
                        .terms
                        .iter()
                        .filter(|t| match t {
                            Src::Const(_) => true,
                            Src::Var(v) => bound[*v],
                        })
                        .count()
                };
                let mut best = remaining[0];
                for &i in &remaining[1..] {
                    if score(i) > score(best) {
                        best = i;
                    }
                }
                best
            }
        };
        remaining.retain(|&i| i != pick);
        let atom = &rule.pos[pick];

        let mut key = Vec::new();
        let mut binds: Vec<(usize, usize)> = Vec::new();
        let mut checks = Vec::new();
        for (pos, t) in atom.terms.iter().enumerate() {
            match *t {
                Src::Const(_) => key.push((pos, *t)),
                Src::Var(v) if bound[v] => key.push((pos, *t)),
                Src::Var(v) => {
                    if binds.iter().any(|&(_, s)| s == v) {
                        checks.push((pos, v));
                    } else {
                        binds.push((pos, v));
                    }
                }
            }
        }
        for &(_, v) in &binds {
            bound[v] = true;
        }

        let limit = match delta {
            Some(d) if d == pick => Limit::Delta,
            Some(d) if pick < d && in_component[atom.pred] => Limit::Old,
            _ => Limit::All,
        };
        let access = if limit == Limit::Delta || key.is_empty() {
            Access::Scan
        } else if key.len() == atom.terms.len() {
            Access::Point
        } else {
            let positions: Vec<usize> = key.iter().map(|&(p, _)| p).collect();
            Access::Index(rels[atom.pred].ensure_index(&positions))
        };
        let filters = take_filters(&bound);
        steps.push(Step { pred: atom.pred, limit, access, key, binds, checks, filters });
    }
    debug_assert!(pending_neg.is_empty() && pending_cmp.is_empty(), "unsafe rule reached planner");
    debug_assert!(vars_of(&rule.head.terms).all(|v| bound[v]));
    Plan { head_pred: rule.head.pred, head: rule.head.terms.clone(), nvars: rule.nvars, pre, steps }
}

/// Run `plan` and append the head tuples it derives, that are not yet in the
/// head relation, to `out` (flat, `arity` words each; duplicates possible).
///
/// `ds[p]` is the first id of the delta of predicate `p`; the delta extends
/// to the current end of the relation.
pub(crate) fn execute(plan: &Plan, rels: &[Relation], ds: &[u32], out: &mut Vec<u32>) {
    let mut ex = Exec { plan, rels, ds, vars: vec![0; plan.nvars], out };
    if ex.filters_ok(&plan.pre) {
        ex.run(0);
    }
}

struct Exec<'a> {
    plan: &'a Plan,
    rels: &'a [Relation],
    ds: &'a [u32],
    vars: Vec<u32>,
    out: &'a mut Vec<u32>,
}

impl Exec<'_> {
    #[inline]
    fn val(&self, s: Src) -> u32 {
        match s {
            Src::Const(c) => c,
            Src::Var(v) => self.vars[v],
        }
    }

    fn filters_ok(&self, filters: &[Filter]) -> bool {
        filters.iter().all(|f| match f {
            Filter::Cmp(l, op, r) => op.holds(self.val(*l).cmp(&self.val(*r))),
            Filter::Neg(pred, args) => {
                let mut k: Key = [0; MAX_ARITY];
                for (i, &a) in args.iter().enumerate() {
                    k[i] = self.val(a);
                }
                !self.rels[*pred].contains(&k[..args.len()])
            }
        })
    }

    fn emit(&mut self) {
        let mut k: Key = [0; MAX_ARITY];
        let n = self.plan.head.len();
        for (slot, &src) in k.iter_mut().zip(&self.plan.head) {
            *slot = self.val(src);
        }
        if !self.rels[self.plan.head_pred].contains(&k[..n]) {
            self.out.extend_from_slice(&k[..n]);
        }
    }

    #[inline]
    fn visit(&mut self, depth: usize, step: &Step, t: &[u32]) {
        for &(pos, slot) in &step.binds {
            self.vars[slot] = t[pos];
        }
        for &(pos, slot) in &step.checks {
            if t[pos] != self.vars[slot] {
                return;
            }
        }
        if self.filters_ok(&step.filters) {
            self.run(depth + 1);
        }
    }

    fn run(&mut self, depth: usize) {
        let plan = self.plan;
        let rels = self.rels;
        let Some(step) = plan.steps.get(depth) else {
            self.emit();
            return;
        };
        let rel = &rels[step.pred];
        let len = rel.len() as u32;
        let (lo, hi) = match step.limit {
            Limit::All => (0, len),
            Limit::Old => (0, self.ds[step.pred]),
            Limit::Delta => (self.ds[step.pred], len),
        };
        let mut key: Key = [0; MAX_ARITY];
        for (i, &(_, s)) in step.key.iter().enumerate() {
            key[i] = self.val(s);
        }
        match step.access {
            Access::Scan => {
                'tuples: for id in lo..hi {
                    let t = rel.tuple(id);
                    for (i, &(pos, _)) in step.key.iter().enumerate() {
                        if t[pos] != key[i] {
                            continue 'tuples;
                        }
                    }
                    self.visit(depth, step, t);
                }
            }
            Access::Point => {
                if let Some(id) = rel.find(&key[..step.key.len()]) {
                    if id >= lo && id < hi {
                        self.visit(depth, step, rel.tuple(id));
                    }
                }
            }
            Access::Index(ix) => {
                let mut id = rel.index_head(ix, &key);
                while id != NONE && id < hi {
                    self.visit(depth, step, rel.tuple(id));
                    id = rel.index_next(ix, id);
                }
            }
        }
    }
}
