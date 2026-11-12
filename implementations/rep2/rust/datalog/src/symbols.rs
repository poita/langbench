//! Interning of predicates and constants.
//!
//! The engine never manipulates [`Const`] values directly. All constants of a
//! program are known up front, so they are sorted once and replaced by their
//! rank (`u32`). Comparing two ranks is then the same as comparing the
//! constants, which makes joins, comparisons and output sorting plain integer
//! operations.

use crate::ast::{Const, Literal, Program, Term};
use std::collections::{BTreeSet, HashMap};

/// Dense identifier of a predicate (name and arity) within a [`PredTable`].
pub type PredId = usize;

/// The set of predicates mentioned by the rules of a program.
///
/// A predicate is identified by its name *and* arity: `r/1` and `r/2` are
/// different predicates.
#[derive(Debug, Clone, Default)]
pub struct PredTable {
    list: Vec<(String, usize)>,
    map: HashMap<(String, usize), PredId>,
}

impl PredTable {
    /// Collect every predicate appearing in a rule head or body.
    pub fn from_program(program: &Program) -> Self {
        let mut t = PredTable::default();
        for rule in &program.rules {
            t.intern(&rule.head.pred, rule.head.arity());
            for lit in &rule.body {
                if let Literal::Pos(a) | Literal::Neg(a) = lit {
                    t.intern(&a.pred, a.arity());
                }
            }
        }
        t
    }

    /// Id of `name/arity`, adding it if new.
    pub fn intern(&mut self, name: &str, arity: usize) -> PredId {
        if let Some(&id) = self.map.get(&(name.to_string(), arity)) {
            return id;
        }
        let id = self.list.len();
        self.list.push((name.to_string(), arity));
        self.map.insert((name.to_string(), arity), id);
        id
    }

    /// Id of `name/arity` if it is known.
    pub fn get(&self, name: &str, arity: usize) -> Option<PredId> {
        self.map.get(&(name.to_string(), arity)).copied()
    }

    /// Name of a predicate.
    pub fn name(&self, id: PredId) -> &str {
        &self.list[id].0
    }

    /// Arity of a predicate.
    pub fn arity(&self, id: PredId) -> usize {
        self.list[id].1
    }

    /// Number of predicates.
    pub fn len(&self) -> usize {
        self.list.len()
    }

    /// `true` if there are no predicates.
    pub fn is_empty(&self) -> bool {
        self.list.is_empty()
    }

    /// `name/arity`, for diagnostics.
    pub fn display(&self, id: PredId) -> String {
        format!("{}/{}", self.list[id].0, self.list[id].1)
    }
}

/// Bidirectional mapping between constants and their ranks.
///
/// `id(a) < id(b)` exactly when `a < b` in the language's constant order.
#[derive(Debug, Clone, Default)]
pub struct Universe {
    consts: Vec<Const>,
    ids: HashMap<Const, u32>,
}

impl Universe {
    /// Collect every constant occurring anywhere in `program` (facts, rules
    /// and queries) and rank them.
    pub fn from_program(program: &Program) -> Self {
        let mut set = BTreeSet::new();
        let mut add = |t: &Term| {
            if let Term::Const(c) = t {
                set.insert(c.clone());
            }
        };
        for rule in &program.rules {
            rule.head.args.iter().for_each(&mut add);
            for lit in &rule.body {
                match lit {
                    Literal::Pos(a) | Literal::Neg(a) => a.args.iter().for_each(&mut add),
                    Literal::Cmp(a, _, b) => {
                        add(a);
                        add(b);
                    }
                }
            }
        }
        for q in &program.queries {
            q.args.iter().for_each(&mut add);
        }
        let consts: Vec<Const> = set.into_iter().collect();
        let ids = consts.iter().enumerate().map(|(i, c)| (c.clone(), i as u32)).collect();
        Universe { consts, ids }
    }

    /// Rank of a constant, if it occurs in the program.
    pub fn id(&self, c: &Const) -> Option<u32> {
        self.ids.get(c).copied()
    }

    /// The constant with the given rank.
    pub fn get(&self, id: u32) -> &Const {
        &self.consts[id as usize]
    }

    /// Number of distinct constants.
    pub fn len(&self) -> usize {
        self.consts.len()
    }

    /// `true` if there are no constants.
    pub fn is_empty(&self) -> bool {
        self.consts.is_empty()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::parse;

    #[test]
    fn ranks_follow_constant_order() {
        let p = parse("p(b, 5, a, -2, a0, aa, a_). ?- p(zz, 0, _, _, _, _, _).").unwrap();
        let u = Universe::from_program(&p);
        let order: Vec<String> = (0..u.len() as u32).map(|i| u.get(i).to_string()).collect();
        assert_eq!(order, ["-2", "0", "5", "a", "a0", "a_", "aa", "b", "zz"]);
    }

    #[test]
    fn predicates_are_name_and_arity() {
        let p = parse("r(a). r(a, b). s(X) :- r(X).").unwrap();
        let t = PredTable::from_program(&p);
        assert_eq!(t.len(), 3);
        assert_ne!(t.get("r", 1), t.get("r", 2));
        assert_eq!(t.get("r", 3), None);
    }
}
