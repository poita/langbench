//! Semi-naive bottom-up evaluation of a stratified program.

use crate::analysis::{check_safety, stratify};
use crate::ast::*;
use crate::constant::Constant;
use crate::error::Error;
use crate::hash::FxHashMap;
use crate::plan::{build_plan, execute, CAtom, CRule, Plan, Src};
use crate::relation::Relation;
use std::collections::BTreeSet;

/// The perfect model of a program: one relation per predicate.
///
/// Constants are interned as their rank in the language's total order, so
/// comparing two interned constants compares the constants themselves.
pub struct Model {
    predicates: Vec<Predicate>,
    /// Rank -> constant.
    constants: Vec<Constant>,
    ids: FxHashMap<Constant, u32>,
    relations: Vec<Relation>,
}

/// Check `program` (safety first, then stratification) and compute its
/// perfect model.
///
/// # Errors
/// [`Error::Unsafe`] or [`Error::Unstratifiable`]. Nothing is evaluated if
/// either check fails.
pub fn evaluate(program: &Program) -> Result<Model, Error> {
    check_safety(program)?;
    let strata = stratify(program)?;

    let constants = collect_constants(program);
    let mut ids: FxHashMap<Constant, u32> = FxHashMap::default();
    for (rank, c) in constants.iter().enumerate() {
        ids.insert(c.clone(), rank as u32);
    }
    let npreds = program.predicates.len();
    let mut relations: Vec<Relation> =
        program.predicates.iter().map(|p| Relation::new(p.arity)).collect();

    let mut comp_of = vec![0; npreds];
    for (c, members) in strata.iter().enumerate() {
        for &p in members {
            comp_of[p] = c;
        }
    }

    // Compile rules; facts go straight into their relations afterwards.
    let mut facts: Vec<CAtom> = Vec::new();
    let mut by_comp: Vec<Vec<CRule>> = vec![Vec::new(); strata.len()];
    for rule in &program.rules {
        let c = compile_rule(rule, &ids);
        if rule.body.is_empty() {
            facts.push(c.head);
        } else {
            by_comp[comp_of[c.head.pred]].push(c);
        }
    }

    // Plan every rule: non-recursive rules once, recursive rules once per
    // recursive body atom.
    let mut stage0: Vec<Vec<Plan>> = vec![Vec::new(); strata.len()];
    let mut variants: Vec<Vec<Plan>> = vec![Vec::new(); strata.len()];
    for (c, rules) in by_comp.iter().enumerate() {
        let in_component: Vec<bool> = (0..npreds).map(|p| comp_of[p] == c).collect();
        for rule in rules {
            let rec: Vec<usize> = (0..rule.pos.len())
                .filter(|&i| in_component[rule.pos[i].pred])
                .collect();
            if rec.is_empty() {
                stage0[c].push(build_plan(rule, None, &in_component, &mut relations));
            } else {
                for i in rec {
                    variants[c].push(build_plan(rule, Some(i), &in_component, &mut relations));
                }
            }
        }
    }

    for f in &facts {
        let tuple: Vec<u32> = f.terms.iter().map(|t| match t {
            Src::Const(c) => *c,
            Src::Var(_) => unreachable!("facts are ground after the safety check"),
        }).collect();
        relations[f.pred].insert(&tuple);
    }

    let mut ds = vec![0u32; npreds];
    let mut bufs: Vec<Vec<u32>> = vec![Vec::new(); npreds];
    for (c, members) in strata.iter().enumerate() {
        // Stage 0: rules that do not read the component itself.
        for plan in &stage0[c] {
            execute(plan, &relations, &ds, &mut bufs[plan.head_pred]);
        }
        flush(&mut relations, &mut bufs);
        if variants[c].is_empty() {
            continue;
        }
        // Rounds: the delta of round 1 is everything in the component so
        // far; afterwards it is what the previous round added.
        for &p in members {
            ds[p] = 0;
        }
        loop {
            let starts: Vec<usize> = members.iter().map(|&p| relations[p].len()).collect();
            for plan in &variants[c] {
                execute(plan, &relations, &ds, &mut bufs[plan.head_pred]);
            }
            flush(&mut relations, &mut bufs);
            let mut changed = false;
            for (&p, &s) in members.iter().zip(&starts) {
                changed |= relations[p].len() > s;
                ds[p] = s as u32;
            }
            if !changed {
                break;
            }
        }
    }

    Ok(Model { predicates: program.predicates.clone(), constants, ids, relations })
}

/// Insert buffered tuples into their relations and clear the buffers.
fn flush(relations: &mut [Relation], bufs: &mut [Vec<u32>]) {
    for (rel, buf) in relations.iter_mut().zip(bufs.iter_mut()) {
        if buf.is_empty() {
            continue;
        }
        let arity = rel.arity();
        for t in buf.chunks_exact(arity) {
            rel.insert(t);
        }
        buf.clear();
    }
}

fn collect_constants(program: &Program) -> Vec<Constant> {
    let mut set = BTreeSet::new();
    let mut add = |t: &Term| {
        if let Term::Const(c) = t {
            set.insert(c.clone());
        }
    };
    for rule in &program.rules {
        rule.head.terms.iter().for_each(&mut add);
        for lit in &rule.body {
            match lit {
                Literal::Pos(a) | Literal::Neg(a) => a.terms.iter().for_each(&mut add),
                Literal::Cmp(l, _, r) => {
                    add(l);
                    add(r);
                }
            }
        }
    }
    for q in &program.queries {
        q.terms.iter().for_each(&mut add);
    }
    set.into_iter().collect()
}

/// Assigns variable slots within one rule.
struct Numberer<'a> {
    ids: &'a FxHashMap<Constant, u32>,
    names: FxHashMap<&'a str, usize>,
    nvars: usize,
}

impl<'a> Numberer<'a> {
    fn term(&mut self, t: &'a Term) -> Src {
        match t {
            Term::Const(c) => Src::Const(self.ids[c]),
            Term::Var(v) => {
                let n = &mut self.nvars;
                Src::Var(*self.names.entry(v.as_str()).or_insert_with(|| {
                    *n += 1;
                    *n - 1
                }))
            }
            Term::Anon => {
                self.nvars += 1;
                Src::Var(self.nvars - 1)
            }
        }
    }

    fn atom(&mut self, a: &'a Atom) -> CAtom {
        CAtom { pred: a.pred, terms: a.terms.iter().map(|t| self.term(t)).collect() }
    }
}

/// Number the variables of a (safe) rule and replace constants by ranks.
fn compile_rule(rule: &Rule, ids: &FxHashMap<Constant, u32>) -> CRule {
    let mut n = Numberer { ids, names: FxHashMap::default(), nvars: 0 };
    let head = n.atom(&rule.head);
    let (mut pos, mut neg, mut cmps) = (Vec::new(), Vec::new(), Vec::new());
    for lit in &rule.body {
        match lit {
            Literal::Pos(a) => pos.push(n.atom(a)),
            Literal::Neg(a) => neg.push(n.atom(a)),
            Literal::Cmp(l, op, r) => {
                let l = n.term(l);
                let r = n.term(r);
                cmps.push((l, *op, r));
            }
        }
    }
    CRule { head, pos, neg, cmps, nvars: n.nvars }
}

impl Model {
    /// All tuples of the predicate `name/arity`, in ascending order.
    /// Unknown predicates are empty.
    pub fn tuples(&self, name: &str, arity: usize) -> Vec<Vec<Constant>> {
        match self.predicates.iter().position(|p| p.name == name && p.arity == arity) {
            Some(pred) => self.matching(pred, &vec![Term::Anon; arity]),
            None => Vec::new(),
        }
    }

    /// Answer a query atom: the tuples of its predicate that match the
    /// pattern (constants must be equal; a variable repeated in the query
    /// must take the same value at each position; `_` and single variables
    /// match anything), in ascending order. The atom's `pred` must be an id
    /// from the program this model was computed from.
    pub fn query(&self, atom: &Atom) -> Vec<Vec<Constant>> {
        self.matching(atom.pred, &atom.terms)
    }

    fn matching(&self, pred: PredId, pattern: &[Term]) -> Vec<Vec<Constant>> {
        let rel = &self.relations[pred];
        // Constants absent from the program cannot match anything.
        let mut consts: Vec<Option<u32>> = Vec::with_capacity(pattern.len());
        for t in pattern {
            consts.push(match t {
                Term::Const(c) => match self.ids.get(c) {
                    Some(&id) => Some(id),
                    None => return Vec::new(),
                },
                _ => None,
            });
        }
        // For each position holding a repeated variable, the first position
        // with the same name.
        let first: Vec<usize> = (0..pattern.len())
            .map(|i| match &pattern[i] {
                Term::Var(v) => (0..i)
                    .find(|&j| matches!(&pattern[j], Term::Var(w) if w == v))
                    .unwrap_or(i),
                _ => i,
            })
            .collect();
        let mut hits: Vec<&[u32]> = rel
            .iter()
            .filter(|t| {
                (0..t.len()).all(|i| consts[i].is_none_or(|c| t[i] == c) && t[first[i]] == t[i])
            })
            .collect();
        hits.sort_unstable();
        hits.into_iter()
            .map(|t| t.iter().map(|&id| self.constants[id as usize].clone()).collect())
            .collect()
    }
}
