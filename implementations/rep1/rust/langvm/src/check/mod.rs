//! The type checker (pass 4): bidirectional checking of every body, producing
//! the resolved IR.

mod expr;
mod pat;

use crate::ast::{self, Block, Expr, ExprKind, Stmt, StmtKind};
use crate::diag::{err, ErrorKind, Pos, Res};
use crate::infer::Infer;
use crate::ir;
use crate::ir::VarRef;
use crate::program::{Program, TyCx, TyEnv};
use crate::resolve::{Analysis, ItemRef};
use crate::types::*;

struct Binding {
    name: String,
    slot: u16,
    mutable: bool,
    ty: Type,
}

struct Upval {
    name: String,
    parent: VarRef,
    mutable: bool,
    ty: Type,
}

struct Scope {
    bindings: Vec<Binding>,
    saved_next: usize,
}

struct FnCtx {
    scopes: Vec<Scope>,
    next_slot: usize,
    max_slot: usize,
    upvals: Vec<Upval>,
    /// The return type; `None` while it is not yet known (lambda synthesis).
    ret: Option<Type>,
    loop_depth: u32,
}

struct Found {
    vref: VarRef,
    mutable: bool,
    ty: Type,
    captured: bool,
}

/// The state of the body checker.
pub struct Checker<'a> {
    prog: &'a Program,
    module: usize,
    tparams: Vec<TParam>,
    self_bounds: Vec<Bound>,
    self_ty: Option<Type>,
    inf: Infer,
    fstack: Vec<FnCtx>,
    funcs: Vec<Option<ir::Func>>,
}

/// Checks every function body and returns the IR for each function id
/// (user functions, impl methods, default bodies and lambdas).
///
/// # Errors
/// The first body-pass diagnostic in sweep order.
pub fn check_program(an: &Analysis) -> Res<Vec<ir::Func>> {
    let prog = &an.prog;
    let mut ck = Checker {
        prog,
        module: 0,
        tparams: Vec::new(),
        self_bounds: Vec::new(),
        self_ty: None,
        inf: Infer::new(),
        fstack: Vec::new(),
        funcs: (0..prog.fns.len()).map(|_| None).collect(),
    };
    for (mi, module) in an.asts.iter().enumerate() {
        ck.module = mi;
        for (k, item) in module.items.iter().enumerate() {
            match (item, an.items[mi][k]) {
                (ast::Item::Fn(f), ItemRef::Fn(id)) => {
                    let sig = &prog.fns[id as usize].sig;
                    ck.tparams = sig.tparams.clone();
                    ck.self_bounds = Vec::new();
                    ck.self_ty = None;
                    let params: Vec<(String, Type)> = f
                        .params
                        .iter()
                        .zip(sig.params.iter())
                        .map(|(p, t)| (p.name.name.clone(), t.clone()))
                        .collect();
                    let func = ck.function(&f.name.name, None, params, sig.ret_ty(), &f.body, f.pos)?;
                    ck.funcs[id as usize] = Some(func);
                }
                (ast::Item::Trait(t), ItemRef::Trait(tid)) => {
                    for (j, m) in t.methods.iter().enumerate() {
                        if let Some(body) = &m.body {
                            let info = &prog.traits[tid as usize].methods[j];
                            let fid = info.default.unwrap();
                            ck.tparams = Vec::new();
                            ck.self_bounds = vec![Bound::User(tid)];
                            ck.self_ty = Some(Type::Param(SELF_PARAM));
                            let params: Vec<(String, Type)> = m
                                .params
                                .iter()
                                .zip(info.params.iter())
                                .map(|(p, t)| (p.name.name.clone(), t.clone()))
                                .collect();
                            let func = ck.function(
                                &m.name.name,
                                Some(Type::Param(SELF_PARAM)),
                                params,
                                info.ret.clone(),
                                body,
                                m.pos,
                            )?;
                            ck.funcs[fid as usize] = Some(func);
                        }
                    }
                }
                (ast::Item::Impl(i), ItemRef::Impl(iid)) => {
                    let imp = &prog.impls[iid];
                    for (j, m) in i.methods.iter().enumerate() {
                        let fid = imp.own[j];
                        let sig = &prog.fns[fid as usize].sig;
                        ck.tparams = imp.tparams.clone();
                        ck.self_bounds = Vec::new();
                        ck.self_ty = Some(imp.head.clone());
                        let params: Vec<(String, Type)> = m
                            .params
                            .iter()
                            .zip(sig.params.iter())
                            .map(|(p, t)| (p.name.name.clone(), t.clone()))
                            .collect();
                        let body = m.body.as_ref().unwrap();
                        let func = ck.function(
                            &m.name.name,
                            Some(imp.head.clone()),
                            params,
                            sig.ret_ty(),
                            body,
                            m.pos,
                        )?;
                        ck.funcs[fid as usize] = Some(func);
                    }
                }
                _ => {}
            }
        }
    }
    Ok(ck
        .funcs
        .into_iter()
        .map(|f| {
            f.unwrap_or(ir::Func {
                name: String::new(),
                nparams: 0,
                nslots: 0,
                nupvals: 0,
                body: ir::Block::default(),
            })
        })
        .collect())
}

/// Whether the expression diverges (section 11.6).
pub fn diverges_expr(e: &Expr) -> bool {
    match &e.kind {
        ExprKind::Block(b) => diverges_block(b),
        ExprKind::If(_, then, Some(els)) => diverges_block(then) && diverges_expr(els),
        ExprKind::Match(_, arms) => !arms.is_empty() && arms.iter().all(|a| diverges_expr(&a.body)),
        _ => false,
    }
}

/// Whether the block diverges.
pub fn diverges_block(b: &Block) -> bool {
    b.stmts.iter().any(diverges_stmt) || b.tail.as_ref().map_or(false, |t| diverges_expr(t))
}

fn diverges_stmt(s: &Stmt) -> bool {
    match &s.kind {
        StmtKind::Return(_) | StmtKind::Break | StmtKind::Continue => true,
        StmtKind::Let(_, _, e) | StmtKind::Var(_, _, e) => diverges_expr(e),
        StmtKind::Assign(_, e) => diverges_expr(e),
        StmtKind::Expr(e) => diverges_expr(e),
        StmtKind::While(..) | StmtKind::For(..) => false,
    }
}

impl<'a> Checker<'a> {
    // ------------------------------------------------------------ contexts

    fn type_cx(&self) -> TyCx<'_> {
        TyCx {
            module: self.module,
            tparams: &self.tparams,
            self_bounds: &self.self_bounds,
            self_ty: self.self_ty.as_ref(),
        }
    }

    fn env(&self) -> TyEnv<'_> {
        TyEnv { tparams: &self.tparams, self_bounds: &self.self_bounds }
    }

    fn resolve_written(&self, te: &ast::TypeExpr) -> Res<Type> {
        self.prog.resolve_type(te, &self.type_cx())
    }

    /// Whether `t` (resolved deeply) satisfies `b` in the current context.
    fn holds(&self, t: &Type, b: Bound) -> bool {
        let t = self.inf.deep(t);
        self.prog.holds(self.env(), &t, b)
    }

    // ------------------------------------------------------------- scopes

    fn cur(&mut self) -> &mut FnCtx {
        self.fstack.last_mut().expect("function context")
    }

    fn push_scope(&mut self) {
        let c = self.cur();
        let saved = c.next_slot;
        c.scopes.push(Scope { bindings: Vec::new(), saved_next: saved });
    }

    fn pop_scope(&mut self) {
        let c = self.cur();
        let s = c.scopes.pop().expect("scope");
        c.next_slot = s.saved_next;
    }

    fn declare(&mut self, name: &str, mutable: bool, ty: Type) -> u16 {
        let c = self.cur();
        let slot = c.next_slot;
        c.next_slot += 1;
        if c.next_slot > c.max_slot {
            c.max_slot = c.next_slot;
        }
        c.scopes
            .last_mut()
            .expect("scope")
            .bindings
            .push(Binding { name: name.to_string(), slot: slot as u16, mutable, ty });
        slot as u16
    }

    fn lookup_var(&mut self, name: &str) -> Option<Found> {
        let level = self.fstack.len() - 1;
        self.lookup_at(level, name)
    }

    fn lookup_at(&mut self, level: usize, name: &str) -> Option<Found> {
        {
            let c = &self.fstack[level];
            for s in c.scopes.iter().rev() {
                for b in s.bindings.iter().rev() {
                    if b.name == name {
                        return Some(Found {
                            vref: VarRef::Local(b.slot),
                            mutable: b.mutable,
                            ty: b.ty.clone(),
                            captured: false,
                        });
                    }
                }
            }
            if let Some(i) = c.upvals.iter().position(|u| u.name == name) {
                let u = &c.upvals[i];
                return Some(Found {
                    vref: VarRef::Upval(i as u16),
                    mutable: u.mutable,
                    ty: u.ty.clone(),
                    captured: true,
                });
            }
        }
        if level == 0 {
            return None;
        }
        let parent = self.lookup_at(level - 1, name)?;
        let c = &mut self.fstack[level];
        c.upvals.push(Upval {
            name: name.to_string(),
            parent: parent.vref,
            mutable: parent.mutable,
            ty: parent.ty.clone(),
        });
        Some(Found {
            vref: VarRef::Upval((c.upvals.len() - 1) as u16),
            mutable: parent.mutable,
            ty: parent.ty,
            captured: true,
        })
    }

    // ---------------------------------------------------------- functions

    /// Checks one declared function, method or default body.
    fn function(
        &mut self,
        name: &str,
        self_ty: Option<Type>,
        params: Vec<(String, Type)>,
        ret: Type,
        body: &Block,
        missing_pos: Pos,
    ) -> Res<ir::Func> {
        self.inf = Infer::new();
        self.fstack.clear();
        self.fstack.push(FnCtx {
            scopes: Vec::new(),
            next_slot: 0,
            max_slot: 0,
            upvals: Vec::new(),
            ret: Some(ret.clone()),
            loop_depth: 0,
        });
        self.push_scope();
        let mut nparams = 0;
        if let Some(st) = self_ty {
            self.declare("self", false, st);
            nparams += 1;
        }
        for (n, t) in &params {
            self.declare(n, false, t.clone());
            nparams += 1;
        }
        let block = self.fn_body(body, &ret, missing_pos)?;
        let ctx = self.fstack.pop().unwrap();
        Ok(ir::Func { name: name.to_string(), nparams, nslots: ctx.max_slot, nupvals: 0, body: block })
    }

    /// Section 11.6: checks a body whose parameters are already declared in the
    /// current scope.
    fn fn_body(&mut self, body: &Block, ret: &Type, missing_pos: Pos) -> Res<ir::Block> {
        let mut stmts = Vec::new();
        for s in &body.stmts {
            stmts.push(self.stmt(s)?);
        }
        let mut tail = None;
        if let Some(t) = &body.tail {
            tail = Some(self.check(t, ret)?);
        } else if self.inf.shallow(ret) != Type::Unit && !diverges_block(body) {
            return err(ErrorKind::MissingReturn, missing_pos);
        }
        Ok(ir::Block { stmts, tail })
    }

    // ------------------------------------------------------------- blocks

    /// A block in checking mode (section 9.3).
    fn block_check(&mut self, b: &Block, expected: &Type) -> Res<ir::Block> {
        self.push_scope();
        let mut stmts = Vec::new();
        for s in &b.stmts {
            stmts.push(self.stmt(s)?);
        }
        let mut tail = None;
        if let Some(t) = &b.tail {
            tail = Some(self.check(t, expected)?);
        } else if !diverges_block(b) && !self.inf.unify(expected, &Type::Unit) {
            return err(ErrorKind::TypeMismatch, b.pos);
        }
        self.pop_scope();
        Ok(ir::Block { stmts, tail })
    }

    /// A block in synthesis mode: its type is the trailing expression's, or
    /// `Unit`.
    fn block_infer(&mut self, b: &Block) -> Res<(ir::Block, Type)> {
        self.push_scope();
        let mut stmts = Vec::new();
        for s in &b.stmts {
            stmts.push(self.stmt(s)?);
        }
        let mut tail = None;
        let mut ty = Type::Unit;
        if let Some(t) = &b.tail {
            let (e, t) = self.infer(t)?;
            tail = Some(e);
            ty = t;
        }
        self.pop_scope();
        Ok((ir::Block { stmts, tail }, ty))
    }

    /// A statement block (loop body): the tail is synthesised and discarded.
    fn block_stmt(&mut self, b: &Block) -> Res<ir::Block> {
        self.push_scope();
        let mut stmts = Vec::new();
        for s in &b.stmts {
            stmts.push(self.stmt(s)?);
        }
        if let Some(t) = &b.tail {
            let (e, _) = self.infer(t)?;
            stmts.push(ir::Stmt::Expr(e));
        }
        self.pop_scope();
        Ok(ir::Block { stmts, tail: None })
    }

    // --------------------------------------------------------- statements

    fn stmt(&mut self, s: &Stmt) -> Res<ir::Stmt> {
        match &s.kind {
            StmtKind::Let(p, ann, init) => {
                let (e, ty) = match ann {
                    Some(a) => {
                        let t = self.resolve_written(a)?;
                        let e = self.check(init, &t)?;
                        (e, t)
                    }
                    None => self.infer(init)?,
                };
                let ty = self.inf.deep(&ty);
                let mut names = Vec::new();
                let pat = self.check_pat(p, &ty, &mut names)?;
                if !self.irrefutable(&pat) {
                    return err(ErrorKind::RefutablePattern, p.pos);
                }
                Ok(ir::Stmt::Let(pat, e))
            }
            StmtKind::Var(name, ann, init) => {
                let (e, ty) = match ann {
                    Some(a) => {
                        let t = self.resolve_written(a)?;
                        let e = self.check(init, &t)?;
                        (e, t)
                    }
                    None => self.infer(init)?,
                };
                let ty = self.inf.deep(&ty);
                let slot = self.declare(&name.name, true, ty);
                Ok(ir::Stmt::Set(slot, e))
            }
            StmtKind::Assign(target, value) => self.assign(target, value),
            StmtKind::Expr(e) => {
                let (ir, _) = self.infer(e)?;
                Ok(ir::Stmt::Expr(ir))
            }
            StmtKind::Return(value) => self.return_stmt(s.pos, value.as_ref()),
            StmtKind::While(cond, body) => {
                let c = self.check(cond, &Type::Bool)?;
                self.cur().loop_depth += 1;
                let b = self.block_stmt(body)?;
                self.cur().loop_depth -= 1;
                Ok(ir::Stmt::While(c, b))
            }
            StmtKind::For(p, e1, e2, body) => self.for_stmt(p, e1, e2.as_ref(), body),
            StmtKind::Break | StmtKind::Continue => {
                if self.cur().loop_depth == 0 {
                    return err(ErrorKind::BreakOutside, s.pos);
                }
                Ok(if matches!(s.kind, StmtKind::Break) { ir::Stmt::Break } else { ir::Stmt::Continue })
            }
        }
    }

    fn return_stmt(&mut self, pos: Pos, value: Option<&Expr>) -> Res<ir::Stmt> {
        let ret = match self.cur().ret.clone() {
            Some(r) => r,
            None => return err(ErrorKind::CannotInfer, pos),
        };
        match value {
            None => {
                if !self.inf.unify(&ret, &Type::Unit) {
                    return err(ErrorKind::TypeMismatch, pos);
                }
                Ok(ir::Stmt::Return(None))
            }
            Some(e) => {
                if self.inf.shallow(&ret) == Type::Unit {
                    let (ir, t) = self.infer(e)?;
                    if !self.inf.unify(&Type::Unit, &t) {
                        return err(ErrorKind::TypeMismatch, pos);
                    }
                    Ok(ir::Stmt::Return(Some(ir)))
                } else {
                    let ir = self.check(e, &ret)?;
                    Ok(ir::Stmt::Return(Some(ir)))
                }
            }
        }
    }

    fn assign(&mut self, target: &Expr, value: &Expr) -> Res<ir::Stmt> {
        match &target.kind {
            ExprKind::Path(p) if p.qual.is_none() => {
                let found = match self.lookup_var(&p.name.name) {
                    Some(f) => f,
                    None => return err(ErrorKind::UnknownName, p.name.pos),
                };
                if !found.mutable {
                    return err(ErrorKind::AssignImmutable, p.name.pos);
                }
                if found.captured {
                    return err(ErrorKind::AssignCaptured, p.name.pos);
                }
                let ty = self.inf.deep(&found.ty);
                let v = self.check(value, &ty)?;
                match found.vref {
                    VarRef::Local(slot) => Ok(ir::Stmt::Set(slot, v)),
                    VarRef::Upval(_) => err(ErrorKind::AssignCaptured, p.name.pos),
                }
            }
            ExprKind::Index(a, i) => {
                let (air, at) = self.infer(a)?;
                match self.inf.shallow(&at) {
                    Type::List(t) => {
                        let iir = self.check(i, &Type::Int)?;
                        let v = self.check(value, &t)?;
                        Ok(ir::Stmt::SetIndex(air, iir, v))
                    }
                    Type::Map(k, vt) => {
                        let iir = self.check(i, &k)?;
                        let v = self.check(value, &vt)?;
                        Ok(ir::Stmt::SetIndex(air, iir, v))
                    }
                    _ => err(ErrorKind::BadTarget, a.pos),
                }
            }
            _ => err(ErrorKind::BadTarget, target.pos),
        }
    }

    fn for_stmt(
        &mut self,
        p: &ast::Pat,
        e1: &Expr,
        e2: Option<&Expr>,
        body: &Block,
    ) -> Res<ir::Stmt> {
        match e2 {
            None => {
                let (it, st) = self.infer(e1)?;
                let elem = match self.inf.shallow(&st) {
                    Type::List(t) => (*t).clone(),
                    Type::Str => Type::Char,
                    _ => return err(ErrorKind::NotIterable, e1.pos),
                };
                self.push_scope();
                let mut names = Vec::new();
                let pat = self.check_pat(p, &elem, &mut names)?;
                if !self.irrefutable(&pat) {
                    return err(ErrorKind::RefutablePattern, p.pos);
                }
                self.cur().loop_depth += 1;
                let b = self.block_stmt(body)?;
                self.cur().loop_depth -= 1;
                self.pop_scope();
                Ok(ir::Stmt::ForSeq(pat, it, b))
            }
            Some(e2) => {
                let lo = self.check(e1, &Type::Int)?;
                let hi = self.check(e2, &Type::Int)?;
                self.push_scope();
                let mut names = Vec::new();
                let pat = self.check_pat(p, &Type::Int, &mut names)?;
                if !self.irrefutable(&pat) {
                    return err(ErrorKind::RefutablePattern, p.pos);
                }
                self.cur().loop_depth += 1;
                let b = self.block_stmt(body)?;
                self.cur().loop_depth -= 1;
                self.pop_scope();
                Ok(ir::Stmt::ForRange(pat, lo, hi, b))
            }
        }
    }
}
