//! The CDCL search engine.
//!
//! A MiniSat-style solver: two watched literals per clause, first-UIP conflict
//! analysis with local clause minimisation, VSIDS branching with phase saving,
//! Luby restarts and periodic deletion of low-activity learnt clauses.

use crate::heap::VarHeap;
use crate::lit::{LBool, Lit, Var};

/// Outcome of [`Solver::solve`].
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SolveResult {
    /// Satisfiable; `model[i]` is the value of variable `Var(i)`
    /// (DIMACS variable `i + 1`).
    Sat(Vec<bool>),
    /// Unsatisfiable.
    Unsat,
}

/// Counters describing the work done by a solver.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Stats {
    /// Number of decisions taken.
    pub decisions: u64,
    /// Number of conflicts analysed.
    pub conflicts: u64,
    /// Number of literal assignments propagated.
    pub propagations: u64,
    /// Number of restarts.
    pub restarts: u64,
    /// Number of learnt-clause database reductions.
    pub reductions: u64,
}

type CRef = u32;

const VAR_DECAY: f64 = 0.95;
const CLA_DECAY: f64 = 0.999;
const VAR_RESCALE_LIMIT: f64 = 1e100;
const CLA_RESCALE_LIMIT: f64 = 1e20;
const RESTART_BASE: f64 = 100.0;
const MAX_LEARNTS_FLOOR: f64 = 2000.0;
const MAX_LEARNTS_GROWTH: f64 = 1.1;

#[derive(Debug)]
struct Clause {
    lits: Vec<Lit>,
    learnt: bool,
    deleted: bool,
    activity: f64,
}

#[derive(Clone, Copy, Debug)]
struct Watcher {
    cref: CRef,
    /// A literal of the clause that, if true, makes visiting it unnecessary.
    blocker: Lit,
}

/// A CDCL SAT solver.
///
/// ```
/// use cdcl_sat::{Lit, SolveResult, Solver};
///
/// let mut s = Solver::new(2);
/// s.add_clause(&[Lit::from_dimacs(1), Lit::from_dimacs(2)]);
/// s.add_clause(&[Lit::from_dimacs(-1)]);
/// assert_eq!(s.solve(), SolveResult::Sat(vec![false, true]));
/// ```
pub struct Solver {
    ok: bool,
    clauses: Vec<Clause>,
    free: Vec<CRef>,
    learnts: Vec<CRef>,
    /// `watches[l]` lists clauses watching literal `l`; visited when `l` turns false.
    watches: Vec<Vec<Watcher>>,
    /// Value of each literal (indexed by `Lit::index`).
    vals: Vec<LBool>,
    level: Vec<u32>,
    reason: Vec<Option<CRef>>,
    trail: Vec<Lit>,
    trail_lim: Vec<usize>,
    qhead: usize,
    activity: Vec<f64>,
    var_inc: f64,
    cla_inc: f64,
    polarity: Vec<bool>,
    order: VarHeap,
    seen: Vec<bool>,
    max_learnts: f64,
    num_stored: usize,
    stats: Stats,
}

impl Solver {
    /// Creates a solver with `num_vars` variables (`Var(0)..Var(num_vars)`).
    pub fn new(num_vars: usize) -> Solver {
        let mut s = Solver {
            ok: true,
            clauses: Vec::new(),
            free: Vec::new(),
            learnts: Vec::new(),
            watches: Vec::new(),
            vals: Vec::new(),
            level: Vec::new(),
            reason: Vec::new(),
            trail: Vec::new(),
            trail_lim: Vec::new(),
            qhead: 0,
            activity: Vec::new(),
            var_inc: 1.0,
            cla_inc: 1.0,
            polarity: Vec::new(),
            order: VarHeap::new(),
            seen: Vec::new(),
            max_learnts: MAX_LEARNTS_FLOOR,
            num_stored: 0,
            stats: Stats::default(),
        };
        for _ in 0..num_vars {
            s.new_var();
        }
        s
    }

    /// Adds a fresh variable and returns it.
    pub fn new_var(&mut self) -> Var {
        let v = Var(self.activity.len() as u32);
        self.watches.push(Vec::new());
        self.watches.push(Vec::new());
        self.vals.push(LBool::Undef);
        self.vals.push(LBool::Undef);
        self.level.push(0);
        self.reason.push(None);
        self.activity.push(0.0);
        self.polarity.push(false);
        self.seen.push(false);
        self.order.insert(v, &self.activity);
        v
    }

    /// Number of variables.
    pub fn num_vars(&self) -> usize {
        self.activity.len()
    }

    /// Search statistics so far.
    pub fn stats(&self) -> Stats {
        self.stats
    }

    #[inline]
    fn value(&self, l: Lit) -> LBool {
        self.vals[l.index()]
    }

    #[inline]
    fn decision_level(&self) -> u32 {
        self.trail_lim.len() as u32
    }

    /// Adds a clause (at decision level 0) after root simplification:
    /// duplicate literals, tautologies and satisfied clauses are dropped,
    /// false literals removed, and units are assigned and propagated.
    ///
    /// Returns `false` if the formula is now known to be unsatisfiable.
    /// Variables beyond the current count are created on demand.
    pub fn add_clause(&mut self, lits: &[Lit]) -> bool {
        if !self.ok {
            return false;
        }
        debug_assert_eq!(self.decision_level(), 0);
        if let Some(max) = lits.iter().map(|l| l.var().index()).max() {
            while self.num_vars() <= max {
                self.new_var();
            }
        }
        let mut c: Vec<Lit> = lits.to_vec();
        c.sort_unstable();
        let mut out: Vec<Lit> = Vec::with_capacity(c.len());
        for &l in &c {
            if self.value(l) == LBool::True {
                return true;
            }
            if out.last() == Some(&l) {
                continue;
            }
            if out.last() == Some(&!l) {
                return true; // tautology (x and !x are adjacent after sorting)
            }
            if self.value(l) == LBool::False {
                continue;
            }
            out.push(l);
        }
        match out.len() {
            0 => {
                self.ok = false;
                false
            }
            1 => {
                self.enqueue(out[0], None);
                self.ok = self.propagate().is_none();
                self.ok
            }
            _ => {
                self.num_stored += 1;
                self.attach(out, false);
                true
            }
        }
    }

    /// Decides satisfiability of the clauses added so far.
    pub fn solve(&mut self) -> SolveResult {
        if !self.ok {
            return SolveResult::Unsat;
        }
        self.max_learnts = (self.num_stored as f64 / 3.0).floor().max(MAX_LEARNTS_FLOOR);
        let mut restart = 0u64;
        let result = loop {
            let budget = (RESTART_BASE * luby(2.0, restart)) as u64;
            match self.search(budget) {
                Some(true) => break self.extract_model(),
                Some(false) => {
                    self.ok = false;
                    break SolveResult::Unsat;
                }
                None => {
                    restart += 1;
                    self.stats.restarts += 1;
                    if self.learnts.len() as f64 >= self.max_learnts {
                        self.reduce_db();
                        self.max_learnts *= MAX_LEARNTS_GROWTH;
                    }
                }
            }
        };
        self.cancel_until(0);
        result
    }

    fn extract_model(&self) -> SolveResult {
        SolveResult::Sat(
            (0..self.num_vars())
                .map(|v| self.vals[Lit::new(Var(v as u32), false).index()] == LBool::True)
                .collect(),
        )
    }

    // ----- clause database -------------------------------------------------

    fn attach(&mut self, lits: Vec<Lit>, learnt: bool) -> CRef {
        debug_assert!(lits.len() >= 2);
        let (a, b) = (lits[0], lits[1]);
        let clause = Clause { lits, learnt, deleted: false, activity: 0.0 };
        let cref = match self.free.pop() {
            Some(r) => {
                self.clauses[r as usize] = clause;
                r
            }
            None => {
                self.clauses.push(clause);
                (self.clauses.len() - 1) as CRef
            }
        };
        self.watches[a.index()].push(Watcher { cref, blocker: b });
        self.watches[b.index()].push(Watcher { cref, blocker: a });
        if learnt {
            self.learnts.push(cref);
        }
        cref
    }

    fn locked(&self, cref: CRef) -> bool {
        let first = self.clauses[cref as usize].lits[0];
        self.value(first) == LBool::True && self.reason[first.var().index()] == Some(cref)
    }

    /// Deletes the lower-activity half of the learnt clauses, keeping binary
    /// (and reason) clauses.
    fn reduce_db(&mut self) {
        self.stats.reductions += 1;
        let mut learnts = std::mem::take(&mut self.learnts);
        {
            let clauses = &self.clauses;
            learnts.sort_by(|&a, &b| {
                clauses[a as usize]
                    .activity
                    .partial_cmp(&clauses[b as usize].activity)
                    .unwrap_or(std::cmp::Ordering::Equal)
            });
        }
        let half = learnts.len() / 2;
        let mut kept = Vec::with_capacity(learnts.len() - half);
        let mut removed = false;
        for (i, &cref) in learnts.iter().enumerate() {
            if i < half && self.clauses[cref as usize].lits.len() > 2 && !self.locked(cref) {
                let c = &mut self.clauses[cref as usize];
                c.deleted = true;
                c.lits = Vec::new();
                self.free.push(cref);
                removed = true;
            } else {
                kept.push(cref);
            }
        }
        self.learnts = kept;
        if removed {
            let clauses = &self.clauses;
            for ws in &mut self.watches {
                ws.retain(|w| !clauses[w.cref as usize].deleted);
            }
        }
    }

    fn bump_clause(&mut self, cref: CRef) {
        self.clauses[cref as usize].activity += self.cla_inc;
        if self.clauses[cref as usize].activity > CLA_RESCALE_LIMIT {
            for &r in &self.learnts {
                self.clauses[r as usize].activity *= 1e-20;
            }
            self.cla_inc *= 1e-20;
        }
    }

    fn bump_var(&mut self, v: Var) {
        self.activity[v.index()] += self.var_inc;
        if self.activity[v.index()] > VAR_RESCALE_LIMIT {
            for a in &mut self.activity {
                *a *= 1e-100;
            }
            self.var_inc *= 1e-100;
        }
        self.order.increased(v, &self.activity);
    }

    // ----- assignment and propagation --------------------------------------

    fn enqueue(&mut self, l: Lit, reason: Option<CRef>) {
        debug_assert_eq!(self.value(l), LBool::Undef);
        let v = l.var().index();
        self.vals[l.index()] = LBool::True;
        self.vals[(!l).index()] = LBool::False;
        self.level[v] = self.decision_level();
        self.reason[v] = reason;
        self.trail.push(l);
    }

    /// Unit propagation with two watched literals. Returns a conflicting clause.
    fn propagate(&mut self) -> Option<CRef> {
        let mut confl = None;
        while self.qhead < self.trail.len() {
            let p = self.trail[self.qhead];
            self.qhead += 1;
            self.stats.propagations += 1;
            let false_lit = !p;
            let mut ws = std::mem::take(&mut self.watches[false_lit.index()]);
            let (mut i, mut j) = (0, 0);
            while i < ws.len() {
                let w = ws[i];
                i += 1;
                if self.vals[w.blocker.index()] == LBool::True {
                    ws[j] = w;
                    j += 1;
                    continue;
                }
                let lits = &mut self.clauses[w.cref as usize].lits;
                if lits[0] == false_lit {
                    lits.swap(0, 1);
                }
                debug_assert_eq!(lits[1], false_lit);
                let first = lits[0];
                let nw = Watcher { cref: w.cref, blocker: first };
                if first != w.blocker && self.vals[first.index()] == LBool::True {
                    ws[j] = nw;
                    j += 1;
                    continue;
                }
                // Look for a replacement watch.
                let mut found = false;
                for k in 2..lits.len() {
                    if self.vals[lits[k].index()] != LBool::False {
                        lits.swap(1, k);
                        let new_watch = lits[1];
                        self.watches[new_watch.index()].push(nw);
                        found = true;
                        break;
                    }
                }
                if found {
                    continue;
                }
                // Clause is unit or conflicting under the current assignment.
                ws[j] = nw;
                j += 1;
                if self.vals[first.index()] == LBool::False {
                    confl = Some(w.cref);
                    self.qhead = self.trail.len();
                    while i < ws.len() {
                        ws[j] = ws[i];
                        i += 1;
                        j += 1;
                    }
                } else {
                    self.enqueue(first, Some(w.cref));
                }
            }
            ws.truncate(j);
            self.watches[false_lit.index()] = ws;
            if confl.is_some() {
                break;
            }
        }
        confl
    }

    fn new_decision_level(&mut self) {
        self.trail_lim.push(self.trail.len());
    }

    /// Undoes all assignments above `level`, saving phases.
    fn cancel_until(&mut self, level: u32) {
        if self.decision_level() <= level {
            return;
        }
        let start = self.trail_lim[level as usize];
        for idx in (start..self.trail.len()).rev() {
            let l = self.trail[idx];
            let v = l.var();
            self.vals[l.index()] = LBool::Undef;
            self.vals[(!l).index()] = LBool::Undef;
            self.reason[v.index()] = None;
            self.polarity[v.index()] = !l.is_negated();
            self.order.insert(v, &self.activity);
        }
        self.trail.truncate(start);
        self.trail_lim.truncate(level as usize);
        self.qhead = self.trail.len();
    }

    // ----- conflict analysis -----------------------------------------------

    /// First-UIP analysis. Returns the learnt clause (asserting literal first,
    /// a literal of the backjump level second) and the backjump level.
    fn analyze(&mut self, mut confl: CRef) -> (Vec<Lit>, u32) {
        let mut learnt: Vec<Lit> = vec![Lit::from_dimacs(1)]; // slot 0 filled below
        let mut path = 0usize;
        let mut p: Option<Lit> = None;
        let mut idx = self.trail.len();
        let current = self.decision_level();
        loop {
            if self.clauses[confl as usize].learnt {
                self.bump_clause(confl);
            }
            let start = usize::from(p.is_some());
            for j in start..self.clauses[confl as usize].lits.len() {
                let q = self.clauses[confl as usize].lits[j];
                let v = q.var();
                if !self.seen[v.index()] && self.level[v.index()] > 0 {
                    self.bump_var(v);
                    self.seen[v.index()] = true;
                    if self.level[v.index()] >= current {
                        path += 1;
                    } else {
                        learnt.push(q);
                    }
                }
            }
            // Next literal on the trail that took part in the conflict.
            loop {
                idx -= 1;
                if self.seen[self.trail[idx].var().index()] {
                    break;
                }
            }
            let pl = self.trail[idx];
            self.seen[pl.var().index()] = false;
            path -= 1;
            p = Some(pl);
            if path == 0 {
                break;
            }
            confl = self.reason[pl.var().index()].expect("implied literal has a reason");
        }
        learnt[0] = !p.expect("at least one literal at the conflict level");

        // Local minimisation: drop literals whose reason is subsumed by the clause.
        let to_clear: Vec<Lit> = learnt.clone();
        let mut kept = 1;
        for i in 1..learnt.len() {
            let l = learnt[i];
            let redundant = match self.reason[l.var().index()] {
                None => false,
                Some(r) => self.clauses[r as usize].lits[1..]
                    .iter()
                    .all(|q| self.seen[q.var().index()] || self.level[q.var().index()] == 0),
            };
            if !redundant {
                learnt[kept] = l;
                kept += 1;
            }
        }
        learnt.truncate(kept);
        for l in to_clear {
            self.seen[l.var().index()] = false;
        }

        let back_level = if learnt.len() == 1 {
            0
        } else {
            let mut max_i = 1;
            for i in 2..learnt.len() {
                if self.level[learnt[i].var().index()] > self.level[learnt[max_i].var().index()] {
                    max_i = i;
                }
            }
            learnt.swap(1, max_i);
            self.level[learnt[1].var().index()]
        };
        (learnt, back_level)
    }

    // ----- search ----------------------------------------------------------

    /// Runs CDCL until a result is found (`Some`) or `budget` conflicts have
    /// occurred (`None`, after backtracking to level 0).
    fn search(&mut self, budget: u64) -> Option<bool> {
        let mut conflicts = 0u64;
        loop {
            if let Some(confl) = self.propagate() {
                conflicts += 1;
                self.stats.conflicts += 1;
                if self.decision_level() == 0 {
                    return Some(false);
                }
                let (learnt, back_level) = self.analyze(confl);
                self.cancel_until(back_level);
                if learnt.len() == 1 {
                    self.enqueue(learnt[0], None);
                } else {
                    let asserting = learnt[0];
                    let cref = self.attach(learnt, true);
                    self.bump_clause(cref);
                    self.enqueue(asserting, Some(cref));
                }
                self.var_inc /= VAR_DECAY;
                self.cla_inc /= CLA_DECAY;
            } else {
                if conflicts >= budget {
                    self.cancel_until(0);
                    return None;
                }
                let next = loop {
                    match self.order.pop_max(&self.activity) {
                        None => break None,
                        Some(v) if self.value(Lit::new(v, false)) == LBool::Undef => break Some(v),
                        Some(_) => {}
                    }
                };
                let Some(v) = next else {
                    return Some(true);
                };
                self.stats.decisions += 1;
                self.new_decision_level();
                let l = Lit::new(v, !self.polarity[v.index()]);
                self.enqueue(l, None);
            }
        }
    }
}

/// The Luby sequence scaled by `y`: `y^k` for the `x`-th (0-based) element.
fn luby(y: f64, mut x: u64) -> f64 {
    let mut size = 1u64;
    let mut seq = 0i32;
    while size < x + 1 {
        seq += 1;
        size = 2 * size + 1;
    }
    while size - 1 != x {
        size = (size - 1) >> 1;
        seq -= 1;
        x %= size;
    }
    y.powi(seq)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn lits(ds: &[i32]) -> Vec<Lit> {
        ds.iter().map(|&d| Lit::from_dimacs(d)).collect()
    }

    #[test]
    fn luby_sequence() {
        let got: Vec<u32> = (0..15).map(|i| luby(2.0, i) as u32).collect();
        assert_eq!(got, vec![1, 1, 2, 1, 1, 2, 4, 1, 1, 2, 1, 1, 2, 4, 8]);
    }

    #[test]
    fn empty_formula_is_sat() {
        assert_eq!(Solver::new(0).solve(), SolveResult::Sat(vec![]));
    }

    #[test]
    fn empty_clause_is_unsat() {
        let mut s = Solver::new(2);
        assert!(!s.add_clause(&[]));
        assert_eq!(s.solve(), SolveResult::Unsat);
    }

    #[test]
    fn tautology_and_duplicates_are_handled() {
        let mut s = Solver::new(2);
        assert!(s.add_clause(&lits(&[1, -1])));
        assert!(s.add_clause(&lits(&[2, 2, 2])));
        match s.solve() {
            SolveResult::Sat(m) => assert!(m[1]),
            other => panic!("expected SAT, got {other:?}"),
        }
    }

    #[test]
    fn conflicting_units_are_unsat() {
        let mut s = Solver::new(1);
        assert!(s.add_clause(&lits(&[1])));
        assert!(!s.add_clause(&lits(&[-1])));
        assert_eq!(s.solve(), SolveResult::Unsat);
    }

    #[test]
    fn unit_propagation_chain() {
        let mut s = Solver::new(3);
        s.add_clause(&lits(&[1]));
        s.add_clause(&lits(&[-1, 2]));
        s.add_clause(&lits(&[-2, 3]));
        assert_eq!(s.solve(), SolveResult::Sat(vec![true, true, true]));
    }

    #[test]
    fn xor_chain_is_unsat() {
        // x1 xor x2, x2 xor x3, x1 xor x3 cannot all hold.
        let mut s = Solver::new(3);
        for c in [[1, 2], [-1, -2], [2, 3], [-2, -3], [1, 3], [-1, -3]] {
            s.add_clause(&lits(&c));
        }
        assert_eq!(s.solve(), SolveResult::Unsat);
    }

    #[test]
    fn grows_variables_on_demand() {
        let mut s = Solver::new(0);
        s.add_clause(&lits(&[3, -4]));
        assert_eq!(s.num_vars(), 4);
    }
}
