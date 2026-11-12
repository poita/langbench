//! The CDCL solver.
//!
//! A MiniSat-style conflict-driven clause-learning solver:
//!
//! * two-watched-literal unit propagation (with blocking literals);
//! * first-UIP conflict analysis with local (non-recursive) minimisation;
//! * VSIDS branching on a binary heap, with phase saving (initially false);
//! * Luby restarts (`100 * luby(2, i)` conflicts);
//! * periodic deletion of the lower-activity half of the learnt clauses.

use crate::heap::VarHeap;
use crate::lit::{Lit, Var};
use crate::luby::luby;

/// Index of a clause in the solver's clause arena.
type CRef = u32;
const NO_REASON: CRef = u32::MAX;

const VAR_DECAY: f64 = 0.95;
const CLAUSE_DECAY: f64 = 0.999;
const RESTART_BASE: f64 = 100.0;
const LEARNT_GROWTH: f64 = 1.1;
const MIN_MAX_LEARNTS: usize = 2000;

#[derive(Clone, Copy, PartialEq, Eq)]
enum LBool {
    True,
    False,
    Undef,
}

struct Clause {
    lits: Vec<Lit>,
    learnt: bool,
    activity: f64,
}

#[derive(Clone, Copy)]
struct Watcher {
    cref: CRef,
    /// A literal of the clause; if it is true the clause need not be visited.
    blocker: Lit,
}

/// Counters describing a solver run.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Stats {
    /// Number of decisions made.
    pub decisions: u64,
    /// Number of literals propagated.
    pub propagations: u64,
    /// Number of conflicts analysed.
    pub conflicts: u64,
    /// Number of restarts.
    pub restarts: u64,
    /// Number of learnt-clause reductions.
    pub reductions: u64,
}

/// A CDCL SAT solver.
///
/// ```
/// use cdcl_sat::{Lit, Solver};
///
/// let mut s = Solver::new();
/// s.reserve_vars(2);
/// s.add_clause(&[Lit::from_dimacs(1), Lit::from_dimacs(2)]);
/// s.add_clause(&[Lit::from_dimacs(-1)]);
/// assert!(s.solve());
/// assert_eq!(s.model(), vec![false, true]);
/// ```
pub struct Solver {
    /// False once the formula is known to be unsatisfiable.
    ok: bool,
    clauses: Vec<Clause>,
    free: Vec<CRef>,
    learnts: Vec<CRef>,
    /// `watches[l]` holds the clauses in which `!l` is watched; they are
    /// visited when `l` becomes true.
    watches: Vec<Vec<Watcher>>,
    assigns: Vec<LBool>,
    level: Vec<u32>,
    reason: Vec<CRef>,
    trail: Vec<Lit>,
    trail_lim: Vec<usize>,
    qhead: usize,
    activity: Vec<f64>,
    var_inc: f64,
    cla_inc: f64,
    order: VarHeap,
    phase: Vec<bool>,
    seen: Vec<bool>,
    max_learnts: f64,
    model: Vec<bool>,
    stats: Stats,
}

impl Default for Solver {
    fn default() -> Self {
        Solver::new()
    }
}

impl Solver {
    /// Creates a solver with no variables and no clauses.
    pub fn new() -> Solver {
        Solver {
            ok: true,
            clauses: Vec::new(),
            free: Vec::new(),
            learnts: Vec::new(),
            watches: Vec::new(),
            assigns: Vec::new(),
            level: Vec::new(),
            reason: Vec::new(),
            trail: Vec::new(),
            trail_lim: Vec::new(),
            qhead: 0,
            activity: Vec::new(),
            var_inc: 1.0,
            cla_inc: 1.0,
            order: VarHeap::new(),
            phase: Vec::new(),
            seen: Vec::new(),
            max_learnts: MIN_MAX_LEARNTS as f64,
            model: Vec::new(),
            stats: Stats::default(),
        }
    }

    /// Adds a fresh variable and returns it.
    pub fn new_var(&mut self) -> Var {
        let v = Var(self.assigns.len() as u32);
        self.assigns.push(LBool::Undef);
        self.level.push(0);
        self.reason.push(NO_REASON);
        self.activity.push(0.0);
        self.phase.push(false);
        self.seen.push(false);
        self.watches.push(Vec::new());
        self.watches.push(Vec::new());
        self.order.grow_to(v);
        self.order.insert(v, &self.activity);
        v
    }

    /// Ensures the solver has at least `n` variables.
    pub fn reserve_vars(&mut self, n: usize) {
        while self.assigns.len() < n {
            self.new_var();
        }
    }

    /// Number of variables.
    pub fn num_vars(&self) -> usize {
        self.assigns.len()
    }

    /// Number of learnt clauses currently stored.
    pub fn num_learnts(&self) -> usize {
        self.learnts.len()
    }

    /// Statistics of the work done so far.
    pub fn stats(&self) -> Stats {
        self.stats
    }

    /// Adds a clause (a disjunction of literals) to the formula.
    ///
    /// The clause is simplified against the root-level assignment:
    /// duplicate literals and false literals are dropped and satisfied
    /// clauses and tautologies are ignored. A unit clause is assigned and
    /// propagated immediately. Variables must already exist.
    ///
    /// Returns `false` if the formula is now known to be unsatisfiable.
    /// Must not be called while a search is in progress.
    pub fn add_clause(&mut self, lits: &[Lit]) -> bool {
        if !self.ok {
            return false;
        }
        debug_assert_eq!(self.decision_level(), 0);
        let mut ps: Vec<Lit> = lits.to_vec();
        ps.sort_unstable();
        ps.dedup();
        let mut out: Vec<Lit> = Vec::with_capacity(ps.len());
        for (i, &l) in ps.iter().enumerate() {
            // Sorted by encoding, so a variable's two literals are adjacent.
            if i > 0 && ps[i - 1] == !l {
                return true; // tautology
            }
            match self.value(l) {
                LBool::True => return true,
                LBool::False => {}
                LBool::Undef => out.push(l),
            }
        }
        match out.len() {
            0 => {
                self.ok = false;
                false
            }
            1 => {
                self.enqueue(out[0], NO_REASON);
                self.ok = self.propagate().is_none();
                self.ok
            }
            _ => {
                let cr = self.alloc_clause(out, false);
                self.attach(cr);
                true
            }
        }
    }

    /// Decides satisfiability of the clauses added so far.
    ///
    /// On `true`, [`Solver::model`] returns a satisfying assignment.
    pub fn solve(&mut self) -> bool {
        self.model.clear();
        if !self.ok {
            return false;
        }
        let stored = self.clauses.len() - self.free.len() - self.learnts.len();
        self.max_learnts = (stored / 3).max(MIN_MAX_LEARNTS) as f64;

        let mut restart = 0u64;
        let result = loop {
            let budget = (RESTART_BASE * luby(2.0, restart)) as u64;
            match self.search(budget) {
                Some(r) => break r,
                None => {
                    restart += 1;
                    self.stats.restarts += 1;
                    if self.learnts.len() as f64 >= self.max_learnts {
                        self.reduce_db();
                        self.max_learnts *= LEARNT_GROWTH;
                    }
                }
            }
        };
        if result {
            self.model = self.assigns.iter().map(|&a| a == LBool::True).collect();
        } else {
            self.ok = false;
        }
        self.cancel_until(0);
        result
    }

    /// The satisfying assignment found by the last successful
    /// [`Solver::solve`]: entry `i` is the value of variable `i`
    /// (DIMACS variable `i + 1`). Empty if the last call returned `false`.
    pub fn model(&self) -> Vec<bool> {
        self.model.clone()
    }

    // ----- assignment helpers -------------------------------------------

    #[inline]
    fn value(&self, l: Lit) -> LBool {
        match self.assigns[l.var().index()] {
            LBool::Undef => LBool::Undef,
            LBool::True if l.is_positive() => LBool::True,
            LBool::False if !l.is_positive() => LBool::True,
            _ => LBool::False,
        }
    }

    #[inline]
    fn decision_level(&self) -> usize {
        self.trail_lim.len()
    }

    fn enqueue(&mut self, l: Lit, from: CRef) {
        let v = l.var().index();
        debug_assert!(self.assigns[v] == LBool::Undef);
        self.assigns[v] = if l.is_positive() { LBool::True } else { LBool::False };
        self.level[v] = self.decision_level() as u32;
        self.reason[v] = from;
        self.trail.push(l);
    }

    fn cancel_until(&mut self, level: usize) {
        if self.decision_level() <= level {
            return;
        }
        let lim = self.trail_lim[level];
        for i in (lim..self.trail.len()).rev() {
            let l = self.trail[i];
            let v = l.var();
            self.assigns[v.index()] = LBool::Undef;
            self.phase[v.index()] = l.is_positive();
            self.order.insert(v, &self.activity);
        }
        self.trail.truncate(lim);
        self.trail_lim.truncate(level);
        self.qhead = lim;
    }

    // ----- clause database ----------------------------------------------

    fn alloc_clause(&mut self, lits: Vec<Lit>, learnt: bool) -> CRef {
        let c = Clause { lits, learnt, activity: 0.0 };
        if let Some(cr) = self.free.pop() {
            self.clauses[cr as usize] = c;
            cr
        } else {
            self.clauses.push(c);
            (self.clauses.len() - 1) as CRef
        }
    }

    fn attach(&mut self, cr: CRef) {
        let (l0, l1) = {
            let c = &self.clauses[cr as usize];
            (c.lits[0], c.lits[1])
        };
        self.watches[(!l0).index()].push(Watcher { cref: cr, blocker: l1 });
        self.watches[(!l1).index()].push(Watcher { cref: cr, blocker: l0 });
    }

    // ----- propagation --------------------------------------------------

    /// Propagates all queued assignments. Returns a conflicting clause, if any.
    fn propagate(&mut self) -> Option<CRef> {
        let mut confl = None;
        while self.qhead < self.trail.len() {
            let p = self.trail[self.qhead];
            self.qhead += 1;
            self.stats.propagations += 1;
            let false_lit = !p;
            let mut ws = std::mem::take(&mut self.watches[p.index()]);
            let n = ws.len();
            let (mut i, mut j) = (0, 0);
            while i < n {
                let w = ws[i];
                i += 1;
                if self.value(w.blocker) == LBool::True {
                    ws[j] = w;
                    j += 1;
                    continue;
                }
                let cr = w.cref as usize;
                let first = {
                    let lits = &mut self.clauses[cr].lits;
                    if lits[0] == false_lit {
                        lits.swap(0, 1);
                    }
                    debug_assert!(lits[1] == false_lit);
                    lits[0]
                };
                let nw = Watcher { cref: w.cref, blocker: first };
                if first != w.blocker && self.value(first) == LBool::True {
                    ws[j] = nw;
                    j += 1;
                    continue;
                }
                // Look for a new literal to watch.
                let len = self.clauses[cr].lits.len();
                let mut found = false;
                for k in 2..len {
                    let lk = self.clauses[cr].lits[k];
                    if self.value(lk) != LBool::False {
                        self.clauses[cr].lits.swap(1, k);
                        self.watches[(!lk).index()].push(nw);
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
                if self.value(first) == LBool::False {
                    confl = Some(w.cref);
                    self.qhead = self.trail.len();
                    while i < n {
                        ws[j] = ws[i];
                        j += 1;
                        i += 1;
                    }
                } else {
                    self.enqueue(first, w.cref);
                }
            }
            ws.truncate(j);
            self.watches[p.index()] = ws;
            if confl.is_some() {
                break;
            }
        }
        confl
    }

    // ----- activities ---------------------------------------------------

    fn bump_var(&mut self, v: Var) {
        self.activity[v.index()] += self.var_inc;
        if self.activity[v.index()] > 1e100 {
            for a in &mut self.activity {
                *a *= 1e-100;
            }
            self.var_inc *= 1e-100;
        }
        self.order.increased(v, &self.activity);
    }

    fn bump_clause(&mut self, cr: CRef) {
        let c = &mut self.clauses[cr as usize];
        c.activity += self.cla_inc;
        if c.activity > 1e20 {
            for &l in &self.learnts {
                self.clauses[l as usize].activity *= 1e-20;
            }
            self.cla_inc *= 1e-20;
        }
    }

    // ----- conflict analysis --------------------------------------------

    /// First-UIP analysis of `confl`. Returns the learnt clause (asserting
    /// literal first, a literal of the backjump level second) and the level
    /// to backjump to.
    fn analyze(&mut self, mut confl: CRef) -> (Vec<Lit>, usize) {
        let mut learnt: Vec<Lit> = vec![Lit::from_dimacs(1)]; // slot 0 filled below
        let mut path = 0usize;
        let mut p: Option<Lit> = None;
        let mut index = self.trail.len();
        let dl = self.decision_level() as u32;

        loop {
            if self.clauses[confl as usize].learnt {
                self.bump_clause(confl);
            }
            let start = usize::from(p.is_some());
            let len = self.clauses[confl as usize].lits.len();
            for k in start..len {
                let q = self.clauses[confl as usize].lits[k];
                let v = q.var();
                if !self.seen[v.index()] && self.level[v.index()] > 0 {
                    self.bump_var(v);
                    self.seen[v.index()] = true;
                    if self.level[v.index()] >= dl {
                        path += 1;
                    } else {
                        learnt.push(q);
                    }
                }
            }
            loop {
                index -= 1;
                if self.seen[self.trail[index].var().index()] {
                    break;
                }
            }
            let pl = self.trail[index];
            confl = self.reason[pl.var().index()];
            self.seen[pl.var().index()] = false;
            path -= 1;
            p = Some(pl);
            if path == 0 {
                break;
            }
        }
        learnt[0] = !p.unwrap();

        // Local minimisation: drop a literal whose reason clause consists
        // only of literals already in the learnt clause (or at level 0).
        let to_clear = learnt.clone();
        let mut j = 1;
        for i in 1..learnt.len() {
            let l = learnt[i];
            let r = self.reason[l.var().index()];
            let redundant = r != NO_REASON
                && self.clauses[r as usize].lits[1..]
                    .iter()
                    .all(|&q| self.seen[q.var().index()] || self.level[q.var().index()] == 0);
            if !redundant {
                learnt[j] = l;
                j += 1;
            }
        }
        learnt.truncate(j);
        for l in &to_clear {
            self.seen[l.var().index()] = false;
        }

        let bt = if learnt.len() == 1 {
            0
        } else {
            let mut max_i = 1;
            for i in 2..learnt.len() {
                if self.level[learnt[i].var().index()] > self.level[learnt[max_i].var().index()] {
                    max_i = i;
                }
            }
            learnt.swap(1, max_i);
            self.level[learnt[1].var().index()] as usize
        };
        (learnt, bt)
    }

    // ----- search -------------------------------------------------------

    /// Runs CDCL until a result is found (`Some`) or `budget` conflicts have
    /// occurred (`None`, after backtracking to level 0).
    fn search(&mut self, budget: u64) -> Option<bool> {
        let mut conflicts = 0u64;
        loop {
            if let Some(confl) = self.propagate() {
                self.stats.conflicts += 1;
                conflicts += 1;
                if self.decision_level() == 0 {
                    return Some(false);
                }
                let (learnt, bt) = self.analyze(confl);
                self.cancel_until(bt);
                if learnt.len() == 1 {
                    self.enqueue(learnt[0], NO_REASON);
                } else {
                    let first = learnt[0];
                    let cr = self.alloc_clause(learnt, true);
                    self.attach(cr);
                    self.learnts.push(cr);
                    self.bump_clause(cr);
                    self.enqueue(first, cr);
                }
                self.var_inc /= VAR_DECAY;
                self.cla_inc /= CLAUSE_DECAY;
            } else {
                if conflicts >= budget {
                    self.cancel_until(0);
                    return None;
                }
                let next = loop {
                    match self.order.pop_max(&self.activity) {
                        None => return Some(true),
                        Some(v) if self.assigns[v.index()] == LBool::Undef => break v,
                        Some(_) => {}
                    }
                };
                self.stats.decisions += 1;
                self.trail_lim.push(self.trail.len());
                let l = Lit::new(next, self.phase[next.index()]);
                self.enqueue(l, NO_REASON);
            }
        }
    }

    /// Deletes the lower-activity half of the learnt clauses, keeping binary
    /// clauses and clauses that are the reason for an assignment.
    /// Must be called at decision level 0.
    fn reduce_db(&mut self) {
        debug_assert_eq!(self.decision_level(), 0);
        self.stats.reductions += 1;
        let mut order = std::mem::take(&mut self.learnts);
        order.sort_by(|&a, &b| {
            self.clauses[a as usize]
                .activity
                .total_cmp(&self.clauses[b as usize].activity)
        });
        let half = order.len() / 2;
        let mut keep = Vec::with_capacity(order.len() - half);
        let mut dead = vec![false; self.clauses.len()];
        let mut any = false;
        for (i, &cr) in order.iter().enumerate() {
            let c = &self.clauses[cr as usize];
            let locked = self.reason[c.lits[0].var().index()] == cr
                && self.value(c.lits[0]) == LBool::True;
            if i < half && c.lits.len() > 2 && !locked {
                dead[cr as usize] = true;
                any = true;
            } else {
                keep.push(cr);
            }
        }
        self.learnts = keep;
        if !any {
            return;
        }
        for ws in &mut self.watches {
            ws.retain(|w| !dead[w.cref as usize]);
        }
        for (cr, d) in dead.iter().enumerate() {
            if *d {
                self.clauses[cr].lits = Vec::new();
                self.free.push(cr as CRef);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn solve_ints(n: usize, clauses: &[&[i32]]) -> Option<Vec<bool>> {
        let mut s = Solver::new();
        s.reserve_vars(n);
        for c in clauses {
            let lits: Vec<Lit> = c.iter().map(|&d| Lit::from_dimacs(d)).collect();
            s.add_clause(&lits);
        }
        if s.solve() {
            Some(s.model())
        } else {
            None
        }
    }

    #[test]
    fn trivial_cases() {
        assert_eq!(solve_ints(0, &[]), Some(vec![]));
        assert_eq!(solve_ints(1, &[&[]]), None);
        assert_eq!(solve_ints(1, &[&[1], &[-1]]), None);
        assert_eq!(solve_ints(2, &[&[1, -1], &[2]]).unwrap()[1], true);
    }

    #[test]
    fn simplification_handles_duplicates_and_tautologies() {
        let m = solve_ints(3, &[&[1, 1, -2, 3], &[2, -2, 3], &[-1, -1], &[2, 2]]).unwrap();
        assert_eq!(m[0], false);
        assert_eq!(m[1], true);
    }

    #[test]
    fn small_unsat_needs_search() {
        // All 8 sign patterns over 3 variables.
        let mut cl: Vec<Vec<i32>> = vec![];
        for m in 0..8 {
            cl.push((0..3).map(|i| if m >> i & 1 == 1 { i + 1 } else { -(i + 1) }).collect());
        }
        let refs: Vec<&[i32]> = cl.iter().map(|c| c.as_slice()).collect();
        assert_eq!(solve_ints(3, &refs), None);
    }

    #[test]
    fn solver_can_be_queried_after_unsat() {
        let mut s = Solver::new();
        s.reserve_vars(1);
        assert!(s.add_clause(&[Lit::from_dimacs(1)]));
        assert!(!s.add_clause(&[Lit::from_dimacs(-1)]));
        assert!(!s.solve());
        assert!(s.model().is_empty());
    }
}
