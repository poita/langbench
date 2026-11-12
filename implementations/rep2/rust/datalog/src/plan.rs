//! Compilation of a rule into a join plan.
//!
//! A [`Plan`] is an indexed nested-loop join over the rule's positive atoms,
//! in a fixed order, with negated atoms and comparisons attached to the
//! earliest step at which all their variables are bound.
//!
//! Join order: the delta atom (if any) first, then repeatedly the atom with
//! the most bound arguments (constants or already-bound variables), ties
//! broken by body order.

use crate::ast::{Atom, CmpOp, Literal, Rule, Term};
use crate::relation::Relation;
use crate::symbols::{PredId, PredTable, Universe};
use std::collections::{HashMap, HashSet};

/// A value source: a constant rank or a variable slot.
#[derive(Debug, Clone, Copy)]
pub(crate) enum Src {
    Const(u32),
    Slot(usize),
}

/// Which part of a relation a step reads.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Version {
    /// Every tuple present at the start of the round.
    Full,
    /// Only tuples older than the current delta.
    Old,
    /// Only the tuples derived in the previous round.
    Delta,
}

#[derive(Debug, Clone)]
pub(crate) enum Access {
    /// Iterate over a row range, applying `checks`.
    Scan,
    /// Look the bound columns up in an index.
    Probe { index: usize },
    /// Every column is bound: a set membership test.
    Contains,
}

#[derive(Debug, Clone)]
pub(crate) enum Filter {
    Cmp { op: CmpOp, a: Src, b: Src },
    Not { pred: PredId, key: Vec<Src> },
}

#[derive(Debug, Clone)]
pub(crate) struct Step {
    pub pred: PredId,
    pub version: Version,
    pub access: Access,
    /// Probe: index key sources in index-column order. Contains: whole tuple.
    pub key: Vec<Src>,
    /// `(column, source)` equalities to verify on each candidate row.
    pub checks: Vec<(usize, Src)>,
    /// `(column, slot)` assignments performed on each candidate row.
    pub binds: Vec<(usize, usize)>,
    /// Negations and comparisons that become evaluable after this step.
    pub filters: Vec<Filter>,
}

#[derive(Debug, Clone)]
pub(crate) struct Plan {
    pub head_pred: PredId,
    pub head: Vec<Src>,
    /// Filters without variables, checked before the first step.
    pub pre: Vec<Filter>,
    pub steps: Vec<Step>,
    pub slots: usize,
}

struct PendingFilter<'a> {
    vars: Vec<&'a str>,
    kind: FilterKind<'a>,
}

enum FilterKind<'a> {
    Cmp(&'a Term, CmpOp, &'a Term),
    Not(&'a Atom),
}

fn term_vars<'a>(t: &'a Term, out: &mut Vec<&'a str>) {
    if let Term::Var(v) = t {
        out.push(v);
    }
}

/// Compile `rule`.
///
/// `delta` is the body index of the positive atom that reads the delta (or
/// `None` for a plain run over the full relations). Positive atoms before it
/// whose predicate satisfies `in_component` read only the old tuples; all
/// others read the full relation. Indexes the plan needs are created on
/// `relations`.
pub(crate) fn compile(
    rule: &Rule,
    preds: &PredTable,
    universe: &Universe,
    relations: &mut [Relation],
    delta: Option<usize>,
    in_component: &dyn Fn(PredId) -> bool,
) -> Plan {
    let pred_of = |a: &Atom| preds.get(&a.pred, a.arity()).expect("predicate interned");
    let const_id = |c: &crate::ast::Const| universe.id(c).expect("constant interned");

    let mut positives: Vec<(usize, &Atom)> = Vec::new();
    let mut pending: Vec<PendingFilter> = Vec::new();
    for (i, lit) in rule.body.iter().enumerate() {
        match lit {
            Literal::Pos(a) => positives.push((i, a)),
            Literal::Neg(a) => {
                let mut vars = Vec::new();
                a.args.iter().for_each(|t| term_vars(t, &mut vars));
                pending.push(PendingFilter { vars, kind: FilterKind::Not(a) });
            }
            Literal::Cmp(a, op, b) => {
                let mut vars = Vec::new();
                term_vars(a, &mut vars);
                term_vars(b, &mut vars);
                pending.push(PendingFilter { vars, kind: FilterKind::Cmp(a, *op, b) });
            }
        }
    }

    let mut slots: HashMap<&str, usize> = HashMap::new();
    let mut bound: HashSet<&str> = HashSet::new();
    let src_of = |t: &Term, slots: &HashMap<&str, usize>| match t {
        Term::Const(c) => Src::Const(const_id(c)),
        Term::Var(v) => Src::Slot(slots[v.as_str()]),
        Term::Anon => unreachable!("anonymous variable in a bound position (rule is unsafe)"),
    };
    let make_filter = |f: &PendingFilter, slots: &HashMap<&str, usize>| match f.kind {
        FilterKind::Cmp(a, op, b) => Filter::Cmp { op, a: src_of(a, slots), b: src_of(b, slots) },
        FilterKind::Not(a) => Filter::Not {
            pred: pred_of(a),
            key: a.args.iter().map(|t| src_of(t, slots)).collect(),
        },
    };
    // Take every pending filter whose variables are all bound.
    let drain_ready = |pending: &mut Vec<PendingFilter>, bound: &HashSet<&str>, slots: &HashMap<&str, usize>| {
        let mut ready = Vec::new();
        pending.retain(|f| {
            if f.vars.iter().all(|v| bound.contains(v)) {
                ready.push(make_filter(f, slots));
                false
            } else {
                true
            }
        });
        ready
    };

    let pre = drain_ready(&mut pending, &bound, &slots);
    let mut steps = Vec::new();
    let mut remaining: Vec<(usize, &Atom)> = positives;
    let mut first = true;
    while !remaining.is_empty() {
        let pick = if first && delta.is_some() {
            remaining.iter().position(|(i, _)| Some(*i) == delta).expect("delta atom is positive")
        } else {
            let score = |a: &Atom| {
                a.args
                    .iter()
                    .filter(|t| match t {
                        Term::Const(_) => true,
                        Term::Var(v) => bound.contains(v.as_str()),
                        Term::Anon => false,
                    })
                    .count()
            };
            let mut best = 0;
            for k in 1..remaining.len() {
                if score(remaining[k].1) > score(remaining[best].1) {
                    best = k;
                }
            }
            best
        };
        let is_delta_step = first && delta.is_some();
        first = false;
        let (body_idx, atom) = remaining.remove(pick);
        let pred = pred_of(atom);

        // Classify the columns.
        let mut key_cols: Vec<usize> = Vec::new();
        let mut key: Vec<Src> = Vec::new();
        let mut binds: Vec<(usize, usize)> = Vec::new();
        let mut repeats: Vec<(usize, Src)> = Vec::new();
        let mut fresh: HashSet<&str> = HashSet::new();
        for (col, t) in atom.args.iter().enumerate() {
            match t {
                Term::Const(c) => {
                    key_cols.push(col);
                    key.push(Src::Const(const_id(c)));
                }
                Term::Var(v) if bound.contains(v.as_str()) => {
                    key_cols.push(col);
                    key.push(Src::Slot(slots[v.as_str()]));
                }
                Term::Var(v) => {
                    if fresh.insert(v.as_str()) {
                        let n = slots.len();
                        let slot = *slots.entry(v.as_str()).or_insert(n);
                        binds.push((col, slot));
                    } else {
                        repeats.push((col, Src::Slot(slots[v.as_str()])));
                    }
                }
                Term::Anon => {}
            }
        }
        bound.extend(fresh);

        let version = if is_delta_step {
            Version::Delta
        } else if delta.is_some_and(|d| body_idx < d) && in_component(pred) {
            Version::Old
        } else {
            Version::Full
        };
        let arity = atom.arity();
        let (access, key, checks) = if is_delta_step || key_cols.is_empty() {
            // Constants (and the like) are verified row by row.
            let mut checks: Vec<(usize, Src)> = key_cols.iter().copied().zip(key).collect();
            checks.extend(repeats);
            (Access::Scan, Vec::new(), checks)
        } else if key_cols.len() == arity {
            (Access::Contains, key, Vec::new())
        } else {
            let index = relations[pred].ensure_index(&key_cols);
            (Access::Probe { index }, key, repeats)
        };
        let filters = drain_ready(&mut pending, &bound, &slots);
        steps.push(Step { pred, version, access, key, checks, binds, filters });
    }
    assert!(pending.is_empty(), "unsafe rule reached the planner");
    let head = rule.head.args.iter().map(|t| src_of(t, &slots)).collect();
    Plan { head_pred: pred_of(&rule.head), head, pre, steps, slots: slots.len() }
}
