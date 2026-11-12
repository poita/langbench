//! The type graph: an arena of shared nodes with union-find unification,
//! level-based generalisation and instantiation.
//!
//! Types form a DAG stored in a flat arena and addressed by [`Ty`]. Unbound
//! variables are union-find nodes carrying a *level*; binding a variable
//! overwrites its node with a link. Constructor nodes are also linked to their
//! partner after a successful unification, so unifying the same pair of shared
//! sub-terms twice costs O(1) the second time.
//!
//! Every walk (occurs check, generalisation, instantiation, printing) visits
//! each distinct node at most once, using per-node epoch marks, so the cost is
//! proportional to the size of the DAG rather than of the expanded tree. No
//! per-node summaries (cached levels or "is ground" flags) are kept.

use crate::ast::Prim;
use crate::error::TypeError;

/// A handle to a type node in a [`Types`] arena.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Ty(u32);

impl Ty {
    #[inline]
    fn ix(self) -> usize {
        self.0 as usize
    }
}

/// Level given to quantified variables of a type scheme.
const GENERIC: u32 = u32::MAX;

#[derive(Debug)]
enum Node {
    /// Unbound variable (or quantified variable when level == `GENERIC`).
    Var { level: u32 },
    /// Bound variable / unified constructor: forwards to another node.
    Link(Ty),
    Int,
    Bool,
    Unit,
    Arrow(Ty, Ty),
    List(Ty),
    Tuple(Box<[Ty]>),
}

/// A small copyable view of a node's shape (children of tuples are fetched by
/// index, to avoid holding a borrow of the arena).
#[derive(Clone, Copy)]
pub(crate) enum Kind {
    Var(u32),
    Int,
    Bool,
    Unit,
    Arrow(Ty, Ty),
    List(Ty),
    Tuple(usize),
}

/// Arena of type nodes plus the scratch state used by graph walks.
#[derive(Debug)]
pub struct Types {
    nodes: Vec<Node>,
    /// `mark[n] == epoch` means node `n` was visited by the current walk.
    mark: Vec<u32>,
    /// Per-walk result for a visited node.
    memo: Vec<Ty>,
    epoch: u32,
    int: Ty,
    bool_: Ty,
    unit: Ty,
}

impl Default for Types {
    fn default() -> Self {
        Self::new()
    }
}

impl Types {
    /// Creates an arena containing only the primitive types.
    pub fn new() -> Self {
        let mut t = Types {
            nodes: Vec::new(),
            mark: Vec::new(),
            memo: Vec::new(),
            epoch: 0,
            int: Ty(0),
            bool_: Ty(0),
            unit: Ty(0),
        };
        t.int = t.push(Node::Int);
        t.bool_ = t.push(Node::Bool);
        t.unit = t.push(Node::Unit);
        t
    }

    fn push(&mut self, n: Node) -> Ty {
        let t = Ty(self.nodes.len() as u32);
        self.nodes.push(n);
        self.mark.push(0);
        self.memo.push(t);
        t
    }

    /// The `int` type.
    pub fn int(&self) -> Ty {
        self.int
    }
    /// The `bool` type.
    pub fn bool(&self) -> Ty {
        self.bool_
    }
    /// The `unit` type.
    pub fn unit(&self) -> Ty {
        self.unit
    }
    pub(crate) fn prim(&self, p: Prim) -> Ty {
        match p {
            Prim::Int => self.int,
            Prim::Bool => self.bool_,
        }
    }

    /// A fresh unbound variable at `level`.
    pub fn var(&mut self, level: u32) -> Ty {
        self.push(Node::Var { level })
    }
    /// A quantified variable, for building type schemes by hand.
    pub fn generic(&mut self) -> Ty {
        self.push(Node::Var { level: GENERIC })
    }
    /// The function type `a -> b`.
    pub fn arrow(&mut self, a: Ty, b: Ty) -> Ty {
        self.push(Node::Arrow(a, b))
    }
    /// The list type `a list`.
    pub fn list(&mut self, a: Ty) -> Ty {
        self.push(Node::List(a))
    }
    /// A tuple type; `items` must have at least two elements.
    pub fn tuple(&mut self, items: Vec<Ty>) -> Ty {
        debug_assert!(items.len() >= 2);
        self.push(Node::Tuple(items.into_boxed_slice()))
    }

    /// Follows links to the representative node, compressing the path.
    pub(crate) fn repr(&mut self, t: Ty) -> Ty {
        let mut r = t;
        while let Node::Link(n) = &self.nodes[r.ix()] {
            r = *n;
        }
        let mut c = t;
        while c != r {
            match &self.nodes[c.ix()] {
                Node::Link(n) => {
                    let n = *n;
                    self.nodes[c.ix()] = Node::Link(r);
                    c = n;
                }
                _ => break,
            }
        }
        r
    }

    /// Shape of a node; `t` must already be a representative.
    pub(crate) fn kind(&self, t: Ty) -> Kind {
        match &self.nodes[t.ix()] {
            Node::Var { level } => Kind::Var(*level),
            Node::Link(_) => unreachable!("kind() of a linked node"),
            Node::Int => Kind::Int,
            Node::Bool => Kind::Bool,
            Node::Unit => Kind::Unit,
            Node::Arrow(a, b) => Kind::Arrow(*a, *b),
            Node::List(a) => Kind::List(*a),
            Node::Tuple(ts) => Kind::Tuple(ts.len()),
        }
    }

    pub(crate) fn tuple_component(&self, t: Ty, i: usize) -> Ty {
        self.tuple_child(t, i)
    }

    fn tuple_child(&self, t: Ty, i: usize) -> Ty {
        match &self.nodes[t.ix()] {
            Node::Tuple(ts) => ts[i],
            _ => unreachable!(),
        }
    }

    pub(crate) fn begin_walk(&mut self) {
        self.epoch += 1;
    }

    pub(crate) fn visited(&self, t: Ty) -> bool {
        self.mark[t.ix()] == self.epoch
    }

    pub(crate) fn visit(&mut self, t: Ty, result: Ty) {
        self.mark[t.ix()] = self.epoch;
        self.memo[t.ix()] = result;
    }

    pub(crate) fn memo(&self, t: Ty) -> Ty {
        self.memo[t.ix()]
    }

    pub(crate) fn raw_index(t: Ty) -> u32 {
        t.0
    }

    pub(crate) fn from_raw_index(i: u32) -> Ty {
        Ty(i)
    }

    // ---------------------------------------------------------------- unify

    /// Unifies `a` and `b`, left to right, binding variables as it goes.
    ///
    /// Errors are [`TypeError::Occurs`] when a variable would be bound to a
    /// type containing itself and [`TypeError::Unify`] for any other clash.
    pub fn unify(&mut self, a: Ty, b: Ty) -> Result<(), TypeError> {
        let a = self.repr(a);
        let b = self.repr(b);
        if a == b {
            return Ok(());
        }
        let (ka, kb) = (self.kind(a), self.kind(b));
        match (ka, kb) {
            (Kind::Var(level), _) => self.bind(a, level, b),
            (_, Kind::Var(level)) => self.bind(b, level, a),
            (Kind::Int, Kind::Int) | (Kind::Bool, Kind::Bool) | (Kind::Unit, Kind::Unit) => Ok(()),
            (Kind::Arrow(a1, a2), Kind::Arrow(b1, b2)) => {
                self.unify(a1, b1)?;
                self.unify(a2, b2)?;
                self.link(a, b);
                Ok(())
            }
            (Kind::List(x), Kind::List(y)) => {
                self.unify(x, y)?;
                self.link(a, b);
                Ok(())
            }
            (Kind::Tuple(n), Kind::Tuple(m)) if n == m => {
                for i in 0..n {
                    let (x, y) = (self.tuple_child(a, i), self.tuple_child(b, i));
                    self.unify(x, y)?;
                }
                self.link(a, b);
                Ok(())
            }
            _ => Err(TypeError::Unify),
        }
    }

    /// Records that two structurally equal constructor nodes are the same.
    /// Only done after a successful unification, so a failed unification never
    /// merges unequal shared (e.g. scheme-resident) nodes.
    fn link(&mut self, from: Ty, to: Ty) {
        self.nodes[from.ix()] = Node::Link(to);
    }

    /// Binds unbound variable `v` (at `level`) to `t`, after an occurs check
    /// that also lowers the levels of the variables reachable from `t`.
    fn bind(&mut self, v: Ty, level: u32, t: Ty) -> Result<(), TypeError> {
        self.begin_walk();
        if self.adjust(v, level, t) {
            return Err(TypeError::Occurs);
        }
        self.nodes[v.ix()] = Node::Link(t);
        Ok(())
    }

    /// Occurs check of `v` in `t`, lowering variable levels above `level`.
    /// Returns true if `v` occurs.
    fn adjust(&mut self, v: Ty, level: u32, t: Ty) -> bool {
        let t = self.repr(t);
        if t == v {
            return true;
        }
        if self.visited(t) {
            return false;
        }
        self.visit(t, t);
        match self.kind(t) {
            Kind::Var(l) => {
                if l > level {
                    self.nodes[t.ix()] = Node::Var { level };
                }
                false
            }
            Kind::Int | Kind::Bool | Kind::Unit => false,
            Kind::Arrow(a, b) => self.adjust(v, level, a) || self.adjust(v, level, b),
            Kind::List(a) => self.adjust(v, level, a),
            Kind::Tuple(n) => {
                for i in 0..n {
                    let c = self.tuple_child(t, i);
                    if self.adjust(v, level, c) {
                        return true;
                    }
                }
                false
            }
        }
    }

    // -------------------------------------------------------- generalisation

    /// Quantifies every unbound variable of `t` whose level is above `level`.
    /// Returns whether `t` ended up containing any quantified variable.
    pub fn generalize(&mut self, t: Ty, level: u32) -> bool {
        self.begin_walk();
        self.gen(t, level)
    }

    fn gen(&mut self, t: Ty, level: u32) -> bool {
        let t = self.repr(t);
        if self.visited(t) {
            return false;
        }
        self.visit(t, t);
        match self.kind(t) {
            Kind::Var(l) => {
                if l > level {
                    self.nodes[t.ix()] = Node::Var { level: GENERIC };
                    true
                } else {
                    l == GENERIC
                }
            }
            Kind::Int | Kind::Bool | Kind::Unit => false,
            Kind::Arrow(a, b) => {
                let x = self.gen(a, level);
                let y = self.gen(b, level);
                x || y
            }
            Kind::List(a) => self.gen(a, level),
            Kind::Tuple(n) => {
                let mut any = false;
                for i in 0..n {
                    let c = self.tuple_child(t, i);
                    any |= self.gen(c, level);
                }
                any
            }
        }
    }

    // --------------------------------------------------------- instantiation

    /// Copies a type scheme: quantified variables become fresh variables at
    /// `level`; sub-terms without quantified variables are shared, not copied.
    pub fn instantiate(&mut self, t: Ty, level: u32) -> Ty {
        self.begin_walk();
        self.inst(t, level)
    }

    fn inst(&mut self, t: Ty, level: u32) -> Ty {
        let t = self.repr(t);
        if self.visited(t) {
            return self.memo(t);
        }
        let r = match self.kind(t) {
            Kind::Var(l) => {
                if l == GENERIC {
                    self.var(level)
                } else {
                    t
                }
            }
            Kind::Int | Kind::Bool | Kind::Unit => t,
            Kind::Arrow(a, b) => {
                let a = self.repr(a);
                let b = self.repr(b);
                let a2 = self.inst(a, level);
                let b2 = self.inst(b, level);
                if a2 == a && b2 == b {
                    t
                } else {
                    self.arrow(a2, b2)
                }
            }
            Kind::List(a) => {
                let a = self.repr(a);
                let a2 = self.inst(a, level);
                if a2 == a {
                    t
                } else {
                    self.list(a2)
                }
            }
            Kind::Tuple(n) => {
                let mut changed = false;
                let mut items = Vec::with_capacity(n);
                for i in 0..n {
                    let c = self.tuple_child(t, i);
                    let c = self.repr(c);
                    let c2 = self.inst(c, level);
                    changed |= c2 != c;
                    items.push(c2);
                }
                if changed {
                    self.tuple(items)
                } else {
                    t
                }
            }
        };
        self.visit(t, r);
        r
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unify_binds_variables() {
        let mut ts = Types::new();
        let a = ts.var(1);
        let i = ts.int();
        let l = ts.list(a);
        let li = ts.list(i);
        ts.unify(l, li).unwrap();
        assert_eq!(ts.render(a), "int");
    }

    #[test]
    fn occurs_check() {
        let mut ts = Types::new();
        let a = ts.var(1);
        let l = ts.list(a);
        assert_eq!(ts.unify(a, l), Err(TypeError::Occurs));
    }

    #[test]
    fn tuple_arity_mismatch() {
        let mut ts = Types::new();
        let (i, b) = (ts.int(), ts.bool());
        let t2 = ts.tuple(vec![i, i]);
        let t3 = ts.tuple(vec![i, i, b]);
        assert_eq!(ts.unify(t2, t3), Err(TypeError::Unify));
    }

    #[test]
    fn failed_unify_does_not_merge_ground_nodes() {
        let mut ts = Types::new();
        let (i, b) = (ts.int(), ts.bool());
        let x = ts.list(i);
        let y = ts.list(b);
        assert!(ts.unify(x, y).is_err());
        assert_eq!(ts.render(x), "int list");
    }

    #[test]
    fn instantiate_copies_generics_and_shares_ground() {
        let mut ts = Types::new();
        let g = ts.generic();
        let i = ts.int();
        let li = ts.list(i);
        let scheme = ts.arrow(g, li);
        let t1 = ts.instantiate(scheme, 1);
        let t2 = ts.instantiate(scheme, 1);
        assert_ne!(t1, t2);
        assert_eq!(ts.render(t1), "'a -> int list");
        assert_eq!(ts.render(scheme), "'a -> int list");
    }

    #[test]
    fn generalize_respects_levels() {
        let mut ts = Types::new();
        let outer = ts.var(1);
        let inner = ts.var(2);
        let t = ts.arrow(outer, inner);
        assert!(ts.generalize(t, 1));
        let inst = ts.instantiate(t, 1);
        // `outer` is shared, `inner` was copied.
        match ts.kind(inst) {
            Kind::Arrow(a, b) => {
                assert_eq!(a, outer);
                assert_ne!(b, inner);
            }
            _ => panic!(),
        }
    }
}
