//! Algorithm J: one left-to-right pass that unifies as it goes.

use crate::ast::{Decl, Expr};
use crate::env::{Binding, Env};
use crate::error::TypeError;
use crate::symbol::Sym;
use crate::types::{Ty, Types};

/// Inference state for one top-level declaration.
pub(crate) struct Infer<'a> {
    pub types: &'a mut Types,
    pub env: &'a mut Env,
    /// Current let-nesting level; variables created here have this level.
    pub level: u32,
}

type IResult = Result<Ty, TypeError>;

impl<'a> Infer<'a> {
    fn unify(&mut self, a: Ty, b: Ty) -> Result<(), TypeError> {
        self.types.unify(a, b)
    }

    fn fresh(&mut self) -> Ty {
        self.types.var(self.level)
    }

    /// Generalises `t` (inferred one level deeper than the current one) into
    /// a binding. A type with no quantified variable is kept monomorphic so
    /// that using it costs O(1).
    fn generalize(&mut self, t: Ty) -> Binding {
        let poly = self.types.generalize(t, self.level);
        Binding { ty: t, poly }
    }

    pub fn infer(&mut self, e: &Expr) -> IResult {
        match e {
            Expr::Int => Ok(self.types.int()),
            Expr::Bool(_) => Ok(self.types.bool()),
            Expr::Unit => Ok(self.types.unit()),
            Expr::Var(x) => {
                let b = self.env.get(*x).ok_or(TypeError::Unbound)?;
                Ok(if b.poly { self.types.instantiate(b.ty, self.level) } else { b.ty })
            }
            Expr::Fun(params, body) => self.lambda(params, body),
            Expr::App(f, a) => {
                let tf = self.infer(f)?;
                let ta = self.infer(a)?;
                let r = self.fresh();
                let fun = self.types.arrow(ta, r);
                self.unify(tf, fun)?;
                Ok(r)
            }
            Expr::Binary(op, l, r) => {
                let (operand, result) = op.signature();
                let (operand, result) = (self.types.prim(operand), self.types.prim(result));
                let tl = self.infer(l)?;
                self.unify(tl, operand)?;
                let tr = self.infer(r)?;
                self.unify(tr, operand)?;
                Ok(result)
            }
            Expr::Cons(h, t) => {
                let th = self.infer(h)?;
                let tt = self.infer(t)?;
                let list = self.types.list(th);
                self.unify(tt, list)?;
                Ok(list)
            }
            Expr::If(c, a, b) => {
                let tc = self.infer(c)?;
                let bool_ = self.types.bool();
                self.unify(tc, bool_)?;
                let ta = self.infer(a)?;
                let tb = self.infer(b)?;
                self.unify(ta, tb)?;
                Ok(ta)
            }
            Expr::Let { name, rhs, body } => {
                self.level += 1;
                let t = self.infer(rhs);
                self.level -= 1;
                let binding = self.generalize(t?);
                self.env.push(*name, binding);
                let r = self.infer(body);
                self.env.pop();
                r
            }
            Expr::LetRec { name, params, rhs, body } => {
                let binding = self.rec_binding(*name, params, rhs)?;
                self.env.push(*name, binding);
                let r = self.infer(body);
                self.env.pop();
                r
            }
            Expr::Tuple(items) => {
                let mut tys = Vec::with_capacity(items.len());
                for it in items {
                    tys.push(self.infer(it)?);
                }
                Ok(self.types.tuple(tys))
            }
            Expr::List(items) => {
                let elem = self.fresh();
                for it in items {
                    let t = self.infer(it)?;
                    self.unify(t, elem)?;
                }
                Ok(self.types.list(elem))
            }
        }
    }

    /// `fun p1 ... pn -> body`: parameters are monomorphic.
    fn lambda(&mut self, params: &[Sym], body: &Expr) -> IResult {
        let mut tys = Vec::with_capacity(params.len());
        for &p in params {
            let t = self.fresh();
            self.env.push(p, Binding { ty: t, poly: false });
            tys.push(t);
        }
        let r = self.infer(body);
        for _ in params {
            self.env.pop();
        }
        let mut res = r?;
        for &t in tys.iter().rev() {
            res = self.types.arrow(t, res);
        }
        Ok(res)
    }

    /// Infers `let rec name params = rhs` one level down and generalises it.
    /// The name is monomorphic inside its own right-hand side.
    fn rec_binding(&mut self, name: Sym, params: &[Sym], rhs: &Expr) -> Result<Binding, TypeError> {
        self.level += 1;
        let tf = self.fresh();
        self.env.push(name, Binding { ty: tf, poly: false });
        let t = self.lambda(params, rhs);
        self.env.pop();
        let result = t.and_then(|t| self.unify(tf, t));
        self.level -= 1;
        result?;
        Ok(self.generalize(tf))
    }

    /// Infers a top-level declaration at level 1 and generalises at level 0.
    /// Returns the declared name (if any), its type and, for a binding, the
    /// environment entry to add on success.
    pub fn decl(&mut self, d: &Decl) -> Result<(Option<(Sym, Binding)>, Ty), TypeError> {
        debug_assert_eq!(self.level, 0);
        match d {
            Decl::Expr(e) => {
                self.level = 1;
                let t = self.infer(e);
                self.level = 0;
                Ok((None, t?))
            }
            Decl::Let { name, rhs } => {
                self.level = 1;
                let t = self.infer(rhs);
                self.level = 0;
                let t = t?;
                let b = self.generalize(t);
                Ok((Some((*name, b)), t))
            }
            Decl::LetRec { name, params, rhs } => {
                let b = self.rec_binding(*name, params, rhs)?;
                Ok((Some((*name, b)), b.ty))
            }
        }
    }
}
