//! Inference variables and unification.

use crate::types::Type;
use std::rc::Rc;

/// The table of inference variables.
#[derive(Default)]
pub struct Infer {
    vars: Vec<Option<Type>>,
    /// Stack of variable scopes; each generic call or struct literal owns one.
    scopes: Vec<Vec<u32>>,
}

impl Infer {
    /// Creates an empty table.
    pub fn new() -> Infer {
        Infer::default()
    }

    /// Creates a fresh variable, owned by the innermost scope.
    pub fn fresh(&mut self) -> Type {
        let id = self.vars.len() as u32;
        self.vars.push(None);
        if let Some(s) = self.scopes.last_mut() {
            s.push(id);
        }
        Type::Var(id)
    }

    /// Opens a variable scope.
    pub fn push_scope(&mut self) {
        self.scopes.push(Vec::new());
    }

    /// Closes the innermost scope and returns its variables.
    pub fn pop_scope(&mut self) -> Vec<u32> {
        self.scopes.pop().unwrap_or_default()
    }

    /// Follows variable bindings at the top of `t`.
    pub fn shallow(&self, t: &Type) -> Type {
        let mut cur = t.clone();
        loop {
            match &cur {
                Type::Var(v) => match &self.vars[*v as usize] {
                    Some(b) => cur = b.clone(),
                    None => return cur,
                },
                _ => return cur,
            }
        }
    }

    /// Substitutes every solved variable throughout `t`.
    pub fn deep(&self, t: &Type) -> Type {
        match t {
            Type::Var(_) => {
                let s = self.shallow(t);
                if let Type::Var(_) = s {
                    s
                } else {
                    self.deep(&s)
                }
            }
            Type::List(e) => Type::List(Rc::new(self.deep(e))),
            Type::Map(k, v) => Type::map(self.deep(k), self.deep(v)),
            Type::Tuple(ts) => Type::tuple(ts.iter().map(|x| self.deep(x)).collect()),
            Type::Fn(ps, r) => Type::func(ps.iter().map(|x| self.deep(x)).collect(), self.deep(r)),
            Type::Named(d, args) => Type::named(*d, args.iter().map(|x| self.deep(x)).collect()),
            _ => t.clone(),
        }
    }

    /// Whether `t` contains no unsolved variable.
    pub fn is_ground(&self, t: &Type) -> bool {
        match t {
            Type::Var(_) => match self.shallow(t) {
                Type::Var(_) => false,
                s => self.is_ground(&s),
            },
            Type::List(e) => self.is_ground(e),
            Type::Map(k, v) => self.is_ground(k) && self.is_ground(v),
            Type::Tuple(ts) => ts.iter().all(|x| self.is_ground(x)),
            Type::Fn(ps, r) => ps.iter().all(|x| self.is_ground(x)) && self.is_ground(r),
            Type::Named(_, args) => args.iter().all(|x| self.is_ground(x)),
            _ => true,
        }
    }

    fn occurs(&self, v: u32, t: &Type) -> bool {
        match t {
            Type::Var(w) => match self.shallow(t) {
                Type::Var(x) => x == v,
                s => {
                    let _ = w;
                    self.occurs(v, &s)
                }
            },
            Type::List(e) => self.occurs(v, e),
            Type::Map(k, x) => self.occurs(v, k) || self.occurs(v, x),
            Type::Tuple(ts) => ts.iter().any(|x| self.occurs(v, x)),
            Type::Fn(ps, r) => ps.iter().any(|x| self.occurs(v, x)) || self.occurs(v, r),
            Type::Named(_, args) => args.iter().any(|x| self.occurs(v, x)),
            _ => false,
        }
    }

    /// Unifies two types, binding variables as needed.
    pub fn unify(&mut self, a: &Type, b: &Type) -> bool {
        let a = self.shallow(a);
        let b = self.shallow(b);
        match (&a, &b) {
            (Type::Var(x), Type::Var(y)) if x == y => true,
            (Type::Var(x), t) => {
                if self.occurs(*x, t) {
                    return false;
                }
                self.vars[*x as usize] = Some(t.clone());
                true
            }
            (t, Type::Var(y)) => {
                if self.occurs(*y, t) {
                    return false;
                }
                self.vars[*y as usize] = Some(t.clone());
                true
            }
            (Type::List(x), Type::List(y)) => self.unify(x, y),
            (Type::Map(k1, v1), Type::Map(k2, v2)) => self.unify(k1, k2) && self.unify(v1, v2),
            (Type::Tuple(x), Type::Tuple(y)) => {
                x.len() == y.len() && x.iter().zip(y.iter()).all(|(p, q)| self.unify(p, q))
            }
            (Type::Fn(p1, r1), Type::Fn(p2, r2)) => {
                p1.len() == p2.len()
                    && p1.iter().zip(p2.iter()).all(|(p, q)| self.unify(p, q))
                    && self.unify(r1, r2)
            }
            (Type::Named(d1, a1), Type::Named(d2, a2)) => {
                d1 == d2
                    && a1.len() == a2.len()
                    && a1.iter().zip(a2.iter()).all(|(p, q)| self.unify(p, q))
            }
            _ => a == b,
        }
    }
}
