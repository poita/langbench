//! Semi-naive bottom-up evaluation of a stratified program.

use crate::analysis::{check_safety, stratify, Stratification};
use crate::ast::{Atom, Const, Program, Term};
use crate::error::Error;
use crate::join::{self, Delta};
use crate::plan::{self, Plan};
use crate::relation::Relation;
use crate::symbols::{PredId, Universe};
use std::collections::HashMap;

/// The perfect model of a program: one [`Relation`] per predicate.
///
/// Built by [`Model::compute`]; queried with [`Model::query`].
#[derive(Debug)]
pub struct Model {
    universe: Universe,
    strat: Stratification,
    relations: Vec<Relation>,
}

/// The plans of one rule inside a recursive component.
struct CompiledRule {
    /// Runs over the full relations (round 0).
    initial: Plan,
    /// One variant per positive body atom of the component; each reads that
    /// atom from the delta.
    variants: Vec<Plan>,
}

impl Model {
    /// Check `program` for safety and stratifiability, then compute its
    /// stratified model.
    ///
    /// Components of the predicate dependency graph are evaluated in
    /// topological order. A non-recursive component runs each rule once; a
    /// recursive one runs semi-naive rounds until no new tuple appears.
    pub fn compute(program: &Program) -> Result<Model, Error> {
        check_safety(program)?;
        let strat = stratify(program)?;
        let universe = Universe::from_program(program);
        let preds = &strat.preds;
        let mut relations: Vec<Relation> = (0..preds.len()).map(|p| Relation::new(preds.arity(p))).collect();

        // Compile every rule (this also creates the indexes) and group the
        // rules by the component of their head.
        let mut compiled: Vec<Vec<CompiledRule>> = (0..strat.components.len()).map(|_| Vec::new()).collect();
        let mut facts: Vec<(PredId, Vec<u32>)> = Vec::new();
        for rule in &program.rules {
            let head = preds.get(&rule.head.pred, rule.head.arity()).expect("interned");
            if rule.is_fact() {
                let tuple = rule
                    .head
                    .args
                    .iter()
                    .map(|t| match t {
                        Term::Const(c) => universe.id(c).expect("interned"),
                        _ => unreachable!("facts are ground after the safety check"),
                    })
                    .collect();
                facts.push((head, tuple));
                continue;
            }
            let comp = strat.component_of[head];
            let in_component = |p: PredId| strat.component_of[p] == comp;
            let initial = plan::compile(rule, preds, &universe, &mut relations, None, &in_component);
            let mut variants = Vec::new();
            if strat.components[comp].recursive {
                for (i, lit) in rule.body.iter().enumerate() {
                    if let crate::ast::Literal::Pos(a) = lit {
                        if in_component(preds.get(&a.pred, a.arity()).unwrap()) {
                            variants.push(plan::compile(rule, preds, &universe, &mut relations, Some(i), &in_component));
                        }
                    }
                }
            }
            compiled[comp].push(CompiledRule { initial, variants });
        }
        for (p, tuple) in facts {
            relations[p].insert(&tuple);
        }

        let mut model = Model { universe, strat, relations };
        for (c, rules) in compiled.iter().enumerate() {
            model.evaluate_component(c, rules);
        }
        Ok(model)
    }

    fn evaluate_component(&mut self, c: usize, rules: &[CompiledRule]) {
        if rules.is_empty() {
            return;
        }
        let comp = &self.strat.components[c];
        let mut deltas = vec![Delta::default(); self.relations.len()];
        let mut buffers: Vec<Vec<u32>> = vec![Vec::new(); self.relations.len()];

        // Round 0: every rule over the relations as they stand.
        for r in rules {
            join::run(&r.initial, &self.relations, &deltas, &mut buffers[r.initial.head_pred]);
        }
        let mut any = commit(&mut self.relations, &mut buffers, &mut deltas, &comp.preds);
        // Rounds 1…: one variant per recursive atom, reading it from the delta.
        while comp.recursive && any {
            for r in rules {
                for v in &r.variants {
                    join::run(v, &self.relations, &deltas, &mut buffers[v.head_pred]);
                }
            }
            any = commit(&mut self.relations, &mut buffers, &mut deltas, &comp.preds);
        }
    }

    /// The relation of `name/arity`, as sorted tuples; empty if the predicate
    /// does not occur in the program.
    pub fn tuples(&self, name: &str, arity: usize) -> Vec<Vec<Const>> {
        let pattern = Atom { pred: name.to_string(), args: vec![Term::Anon; arity] };
        self.query(&pattern)
    }

    /// Number of tuples of `name/arity` (0 if unknown).
    pub fn count(&self, name: &str, arity: usize) -> usize {
        self.strat.preds.get(name, arity).map_or(0, |p| self.relations[p].len())
    }

    /// Answer a query: all tuples matching the pattern, in ascending order.
    ///
    /// Constants in the pattern must match exactly; a variable occurring
    /// several times must match the same constant at each position; `_` and
    /// variables occurring once match anything.
    pub fn query(&self, atom: &Atom) -> Vec<Vec<Const>> {
        enum Pat {
            Any,
            Eq(u32),
            Same(usize),
        }
        let Some(p) = self.strat.preds.get(&atom.pred, atom.arity()) else {
            return Vec::new();
        };
        let mut first: HashMap<&str, usize> = HashMap::new();
        let mut pats = Vec::with_capacity(atom.arity());
        for (i, t) in atom.args.iter().enumerate() {
            pats.push(match t {
                Term::Anon => Pat::Any,
                Term::Const(c) => match self.universe.id(c) {
                    Some(id) => Pat::Eq(id),
                    None => return Vec::new(), // no tuple can contain it
                },
                Term::Var(v) => match first.get(v.as_str()) {
                    Some(&j) => Pat::Same(j),
                    None => {
                        first.insert(v, i);
                        Pat::Any
                    }
                },
            });
        }
        let mut rows: Vec<&[u32]> = self
            .relations[p]
            .iter()
            .filter(|row| {
                pats.iter().enumerate().all(|(i, pat)| match pat {
                    Pat::Any => true,
                    Pat::Eq(c) => row[i] == *c,
                    Pat::Same(j) => row[i] == row[*j],
                })
            })
            .collect();
        rows.sort_unstable();
        rows.into_iter()
            .map(|row| row.iter().map(|&id| self.universe.get(id).clone()).collect())
            .collect()
    }
}

/// Append the buffered tuples to their relations (dropping duplicates) and
/// record each component predicate's new delta. Returns whether anything new
/// was added.
fn commit(
    relations: &mut [Relation],
    buffers: &mut [Vec<u32>],
    deltas: &mut [Delta],
    preds: &[PredId],
) -> bool {
    let mut any = false;
    for &p in preds {
        let rel = &mut relations[p];
        let start = rel.len() as u32;
        let arity = rel.arity();
        for tuple in buffers[p].chunks_exact(arity) {
            rel.insert(tuple);
        }
        buffers[p].clear();
        let end = rel.len() as u32;
        deltas[p] = Delta { start, end };
        any |= end > start;
    }
    any
}
