//! Expression checking: the `infer` and `check` functions of section 9.

use super::{diverges_block, diverges_expr, Checker, FnCtx, Found};
use crate::ast::{self, BinOp, Expr, ExprKind, Ident, UnOp};
use crate::builtins::Builtin;
use crate::diag::{err, ErrorKind, Pos, Res};
use crate::exhaust;
use crate::ir::{self, Arith, Bit, Cmp, Const, Num};
use crate::program::{primitive, DeclKind, PreludeValue, ValueItem};
use crate::types::*;

enum ValRes {
    Local(Found),
    Func(FnId),
    Builtin(Builtin),
    Variant(DeclId, u32),
    TraitMethod(TraitId, usize),
}

impl<'a> Checker<'a> {
    /// Synthesis mode.
    pub(super) fn infer(&mut self, e: &Expr) -> Res<(ir::Expr, Type)> {
        match &e.kind {
            ExprKind::Int(n) => Ok((ir::Expr::Const(Const::Int(*n)), Type::Int)),
            ExprKind::Float(f) => Ok((ir::Expr::Const(Const::Float(*f)), Type::Float)),
            ExprKind::Str(s) => Ok((ir::Expr::Const(Const::Str(s.clone())), Type::Str)),
            ExprKind::Char(c) => Ok((ir::Expr::Const(Const::Char(*c)), Type::Char)),
            ExprKind::Bool(b) => Ok((ir::Expr::Bool(*b), Type::Bool)),
            ExprKind::SelfVal => match self.lookup_var("self") {
                Some(f) => Ok((ir::Expr::Var(f.vref), self.inf.deep(&f.ty))),
                None => err(ErrorKind::SelfOutside, e.pos),
            },
            ExprKind::Path(p) => {
                let (ir, ty, _) = self.path_value(e, p, None)?;
                Ok((ir, ty))
            }
            ExprKind::StructLit(p, fields) => self.struct_lit(p, fields, None),
            ExprKind::Unary(op, x) => self.unary(*op, x),
            ExprKind::Binary(op, l, r) => self.binary(*op, l, r),
            ExprKind::Call(callee, args) => self.call(e, callee, args, None),
            ExprKind::MethodCall(recv, m, args) => self.method_call(e, recv, m, args, None),
            ExprKind::Index(a, i) => self.index(a, i),
            ExprKind::Field(x, f) => self.field(x, f),
            ExprKind::List(items) => {
                if items.is_empty() {
                    return err(ErrorKind::CannotInfer, e.pos);
                }
                let (first, t) = self.infer(&items[0])?;
                let mut out = vec![first];
                for it in &items[1..] {
                    out.push(self.check(it, &t)?);
                }
                Ok((ir::Expr::List(out), Type::list(self.inf.deep(&t))))
            }
            ExprKind::Map(entries) => {
                if entries.is_empty() {
                    return err(ErrorKind::CannotInfer, e.pos);
                }
                let (k1, kt) = self.infer(&entries[0].0)?;
                if !self.holds(&kt, Bound::Key) {
                    return err(ErrorKind::BadKeyType, entries[0].0.pos);
                }
                let (v1, vt) = self.infer(&entries[0].1)?;
                let mut out = vec![(k1, v1)];
                for (k, v) in &entries[1..] {
                    let ki = self.check(k, &kt)?;
                    let vi = self.check(v, &vt)?;
                    out.push((ki, vi));
                }
                Ok((ir::Expr::Map(out), Type::map(self.inf.deep(&kt), self.inf.deep(&vt))))
            }
            ExprKind::Tuple(items) => {
                if items.len() > 8 {
                    return err(ErrorKind::BadArity, e.pos);
                }
                let mut out = Vec::new();
                let mut tys = Vec::new();
                for it in items {
                    let (i, t) = self.infer(it)?;
                    out.push(i);
                    tys.push(self.inf.deep(&t));
                }
                Ok((ir::Expr::Tuple(out), Type::tuple(tys)))
            }
            ExprKind::Lambda(l) => self.lambda(e, l, None),
            ExprKind::If(c, t, els) => self.if_expr(e, c, t, els.as_deref(), None),
            ExprKind::Match(s, arms) => self.match_expr(e, s, arms, None),
            ExprKind::Block(b) => {
                let (blk, t) = self.block_infer(b)?;
                Ok((ir::Expr::Block(Box::new(blk)), t))
            }
        }
    }

    /// The default checking rule: synthesise, then unify with the expectation.
    fn check_default(&mut self, e: &Expr, expected: &Type) -> Res<ir::Expr> {
        let (ir, t) = self.infer(e)?;
        if !self.inf.unify(expected, &t) {
            return err(ErrorKind::TypeMismatch, e.pos);
        }
        Ok(ir)
    }

    /// Checking mode.
    pub(super) fn check(&mut self, e: &Expr, expected: &Type) -> Res<ir::Expr> {
        match &e.kind {
            ExprKind::List(items) => {
                let t = self.inf.shallow(expected);
                let elem = match &t {
                    Type::List(a) => (**a).clone(),
                    Type::Var(_) => {
                        let a = self.inf.fresh();
                        self.inf.unify(&t, &Type::list(a.clone()));
                        a
                    }
                    _ => return err(ErrorKind::TypeMismatch, e.pos),
                };
                let mut out = Vec::new();
                for it in items {
                    out.push(self.check(it, &elem)?);
                }
                Ok(ir::Expr::List(out))
            }
            ExprKind::Map(entries) => {
                let t = self.inf.shallow(expected);
                let (kt, vt) = match &t {
                    Type::Map(k, v) => ((**k).clone(), (**v).clone()),
                    Type::Var(_) => {
                        let k = self.inf.fresh();
                        let v = self.inf.fresh();
                        self.inf.unify(&t, &Type::map(k.clone(), v.clone()));
                        (k, v)
                    }
                    _ => return err(ErrorKind::TypeMismatch, e.pos),
                };
                let mut out = Vec::new();
                for (k, v) in entries {
                    let ki = self.check(k, &kt)?;
                    let vi = self.check(v, &vt)?;
                    out.push((ki, vi));
                }
                let kd = self.inf.deep(&kt);
                if self.inf.is_ground(&kd) && !self.holds(&kd, Bound::Key) {
                    return err(ErrorKind::BadKeyType, e.pos);
                }
                Ok(ir::Expr::Map(out))
            }
            ExprKind::Tuple(items) => {
                if items.len() > 8 {
                    return err(ErrorKind::BadArity, e.pos);
                }
                let t = self.inf.shallow(expected);
                let tys: Vec<Type> = match &t {
                    Type::Tuple(ts) if ts.len() == items.len() => ts.to_vec(),
                    Type::Var(_) => {
                        let ts: Vec<Type> = items.iter().map(|_| self.inf.fresh()).collect();
                        self.inf.unify(&t, &Type::tuple(ts.clone()));
                        ts
                    }
                    _ => return err(ErrorKind::TypeMismatch, e.pos),
                };
                let mut out = Vec::new();
                for (it, ty) in items.iter().zip(tys.iter()) {
                    out.push(self.check(it, ty)?);
                }
                Ok(ir::Expr::Tuple(out))
            }
            ExprKind::Lambda(l) => Ok(self.lambda(e, l, Some(expected))?.0),
            ExprKind::If(c, t, els) => Ok(self.if_expr(e, c, t, els.as_deref(), Some(expected))?.0),
            ExprKind::Match(s, arms) => Ok(self.match_expr(e, s, arms, Some(expected))?.0),
            ExprKind::Block(b) => {
                let blk = self.block_check(b, expected)?;
                Ok(ir::Expr::Block(Box::new(blk)))
            }
            ExprKind::Call(callee, args) => Ok(self.call(e, callee, args, Some(expected))?.0),
            ExprKind::Path(p) => {
                let (ir, ty, done) = self.path_value(e, p, Some(expected))?;
                if !done && !self.inf.unify(expected, &ty) {
                    return err(ErrorKind::TypeMismatch, e.pos);
                }
                Ok(ir)
            }
            ExprKind::StructLit(p, fields) => Ok(self.struct_lit(p, fields, Some(expected))?.0),
            ExprKind::MethodCall(recv, m, args) => {
                Ok(self.method_call(e, recv, m, args, Some(expected))?.0)
            }
            _ => self.check_default(e, expected),
        }
    }

    // ------------------------------------------------------------- paths

    fn resolve_value_path(&mut self, path: &ast::Path) -> Res<ValRes> {
        let prog = self.prog;
        match &path.qual {
            None => {
                let name = path.name.name.as_str();
                if let Some(f) = self.lookup_var(name) {
                    return Ok(ValRes::Local(f));
                }
                if let Some(v) = prog.modules[self.module].values.get(name) {
                    return Ok(match v {
                        ValueItem::Func(f) => ValRes::Func(*f),
                        ValueItem::Variant(d, i) => ValRes::Variant(*d, *i),
                    });
                }
                if let Some(v) = prog.prelude_values.get(name) {
                    return Ok(match v {
                        PreludeValue::Builtin(b) => ValRes::Builtin(*b),
                        PreludeValue::Variant(d, i) => ValRes::Variant(*d, *i),
                    });
                }
                if prog.lookup_type_name(self.module, name).is_some()
                    || primitive(name).is_some()
                    || name == "Self"
                {
                    return err(ErrorKind::BadValueRef, path.name.pos);
                }
                err(ErrorKind::UnknownName, path.name.pos)
            }
            Some(q) => {
                if let Some(m) = prog.import_of(self.module, &q.name) {
                    return match prog.modules[m].values.get(&path.name.name) {
                        None => err(ErrorKind::UnknownName, path.name.pos),
                        Some(ValueItem::Func(f)) => {
                            if !prog.fns[*f as usize].is_pub && m != self.module {
                                err(ErrorKind::NotPublic, path.name.pos)
                            } else {
                                Ok(ValRes::Func(*f))
                            }
                        }
                        Some(ValueItem::Variant(d, i)) => {
                            if !prog.decls[*d as usize].is_pub && m != self.module {
                                err(ErrorKind::NotPublic, path.name.pos)
                            } else {
                                Ok(ValRes::Variant(*d, *i))
                            }
                        }
                    };
                }
                match prog.find_visible_trait(self.module, &q.name) {
                    Some(Bound::User(t)) => {
                        match prog.traits[t as usize].methods.iter().position(|m| m.name == path.name.name) {
                            Some(i) => Ok(ValRes::TraitMethod(t, i)),
                            None => err(ErrorKind::UnknownName, path.name.pos),
                        }
                    }
                    Some(_) => err(ErrorKind::UnknownName, path.name.pos),
                    None => err(ErrorKind::UnknownModule, q.pos),
                }
            }
        }
    }

    /// A path used as a value. Returns the IR, the type, and whether the
    /// expectation (if any) has already been enforced.
    fn path_value(
        &mut self,
        _e: &Expr,
        p: &ast::Path,
        expected: Option<&Type>,
    ) -> Res<(ir::Expr, Type, bool)> {
        match self.resolve_value_path(p)? {
            ValRes::Local(f) => Ok((ir::Expr::Var(f.vref), self.inf.deep(&f.ty), false)),
            ValRes::Variant(d, v) => {
                let decl = &self.prog.decls[d as usize];
                let payload = match &decl.kind {
                    DeclKind::Enum(vs) => &vs[v as usize].payload,
                    _ => unreachable!(),
                };
                if !payload.is_empty() {
                    return err(ErrorKind::BadValueRef, p.name.pos);
                }
                let tparams: Vec<TParam> =
                    decl.tparams.iter().map(|n| TParam { name: n.clone(), bounds: vec![] }).collect();
                let ret = Type::named(d, (0..decl.tparams.len() as u32).map(Type::Param).collect());
                let (_, ty) = self.generic_call(p.pos(), &tparams, &[], &ret, &[], expected)?;
                Ok((ir::Expr::MakeEnum(d, v as u16, vec![]), ty, true))
            }
            _ => err(ErrorKind::BadValueRef, p.name.pos),
        }
    }

    // ------------------------------------------------------------- calls

    /// The generic-call rule of section 9.4.
    fn generic_call(
        &mut self,
        call_pos: Pos,
        tparams: &[TParam],
        params: &[Type],
        ret: &Type,
        args: &[Expr],
        expected: Option<&Type>,
    ) -> Res<(Vec<ir::Expr>, Type)> {
        if args.len() != params.len() {
            return err(ErrorKind::Arity, call_pos);
        }
        self.inf.push_scope();
        let vars: Vec<Type> = tparams.iter().map(|_| self.inf.fresh()).collect();
        let mut irs = Vec::with_capacity(args.len());
        for (a, p) in args.iter().zip(params.iter()) {
            let pt = p.subst_params(&vars);
            irs.push(self.check(a, &pt)?);
        }
        let g = ret.subst_params(&vars);
        if let Some(t) = expected {
            if !self.inf.unify(&g, t) {
                return err(ErrorKind::TypeMismatch, call_pos);
            }
        }
        let scope_vars = self.inf.pop_scope();
        for v in scope_vars {
            if !self.inf.is_ground(&Type::Var(v)) {
                return err(ErrorKind::CannotInfer, call_pos);
            }
        }
        for (tp, v) in tparams.iter().zip(vars.iter()) {
            for b in &tp.bounds {
                if !self.holds(v, *b) {
                    return err(ErrorKind::UnsatisfiedBound, call_pos);
                }
            }
        }
        let ty = self.inf.deep(&g);
        Ok((irs, ty))
    }

    fn call(
        &mut self,
        e: &Expr,
        callee: &Expr,
        args: &[Expr],
        expected: Option<&Type>,
    ) -> Res<(ir::Expr, Type)> {
        if args.len() > 16 {
            return err(ErrorKind::BadArity, callee.pos);
        }
        let mut local: Option<Found> = None;
        if let ExprKind::Path(p) = &callee.kind {
            match self.resolve_value_path(p)? {
                ValRes::Func(f) => {
                    let sig = &self.prog.fns[f as usize].sig;
                    let (irs, ty) = self.generic_call(
                        callee.pos,
                        &sig.tparams,
                        &sig.params,
                        &sig.ret_ty(),
                        args,
                        expected,
                    )?;
                    return Ok((ir::Expr::Call(f, irs), ty));
                }
                ValRes::Builtin(b) => {
                    let sig = &self.prog.builtin_sigs[b as usize];
                    let (irs, ty) = self.generic_call(
                        callee.pos,
                        &sig.tparams,
                        &sig.params,
                        &sig.ret_ty(),
                        args,
                        expected,
                    )?;
                    return Ok((ir::Expr::CallBuiltin(b, irs), ty));
                }
                ValRes::Variant(d, v) => {
                    let decl = &self.prog.decls[d as usize];
                    let payload = match &decl.kind {
                        DeclKind::Enum(vs) => vs[v as usize].payload.clone(),
                        _ => unreachable!(),
                    };
                    let tparams: Vec<TParam> =
                        decl.tparams.iter().map(|n| TParam { name: n.clone(), bounds: vec![] }).collect();
                    let ret = Type::named(d, (0..decl.tparams.len() as u32).map(Type::Param).collect());
                    let (irs, ty) =
                        self.generic_call(callee.pos, &tparams, &payload, &ret, args, expected)?;
                    return Ok((ir::Expr::MakeEnum(d, v as u16, irs), ty));
                }
                ValRes::TraitMethod(t, m) => {
                    if args.is_empty() {
                        return err(ErrorKind::Arity, p.name.pos);
                    }
                    let (rir, rt) = self.infer(&args[0])?;
                    return self.finish_method(e, t, m, rir, rt, &args[1..], p.name.pos, expected);
                }
                ValRes::Local(f) => local = Some(f),
            }
        }
        let (cir, cty) = match local {
            Some(f) => (ir::Expr::Var(f.vref), self.inf.deep(&f.ty)),
            None => self.infer(callee)?,
        };
        let (ps, r) = match self.inf.shallow(&cty) {
            Type::Fn(ps, r) => (ps, r),
            _ => return err(ErrorKind::NotCallable, callee.pos),
        };
        if ps.len() != args.len() {
            return err(ErrorKind::Arity, callee.pos);
        }
        let mut irs = Vec::new();
        for (a, p) in args.iter().zip(ps.iter()) {
            irs.push(self.check(a, p)?);
        }
        let rt = (*r).clone();
        if let Some(t) = expected {
            if !self.inf.unify(t, &rt) {
                return err(ErrorKind::TypeMismatch, e.pos);
            }
        }
        Ok((ir::Expr::CallValue(Box::new(cir), irs), self.inf.deep(&rt)))
    }

    fn method_call(
        &mut self,
        e: &Expr,
        recv: &Expr,
        m: &Ident,
        args: &[Expr],
        expected: Option<&Type>,
    ) -> Res<(ir::Expr, Type)> {
        if args.len() > 16 {
            return err(ErrorKind::BadArity, m.pos);
        }
        let (rir, rt) = self.infer(recv)?;
        let cands = self.prog.traits_with_method(self.module, &m.name);
        if cands.is_empty() {
            return err(ErrorKind::NoMethod, m.pos);
        }
        if cands.len() > 1 {
            return err(ErrorKind::AmbigMethod, m.pos);
        }
        let tr = cands[0];
        let midx = self.prog.traits[tr as usize].methods.iter().position(|x| x.name == m.name).unwrap();
        self.finish_method(e, tr, midx, rir, rt, args, m.pos, expected)
    }

    #[allow(clippy::too_many_arguments)]
    fn finish_method(
        &mut self,
        e: &Expr,
        tr: TraitId,
        midx: usize,
        rir: ir::Expr,
        rt: Type,
        args: &[Expr],
        name_pos: Pos,
        expected: Option<&Type>,
    ) -> Res<(ir::Expr, Type)> {
        let sig = self.prog.traits[tr as usize].methods[midx].clone();
        if args.len() != sig.params.len() {
            return err(ErrorKind::Arity, name_pos);
        }
        let r = self.inf.deep(&rt);
        if !self.holds(&r, Bound::User(tr)) {
            return err(ErrorKind::UnsatisfiedBound, name_pos);
        }
        let mut irs = Vec::new();
        for (a, p) in args.iter().zip(sig.params.iter()) {
            irs.push(self.check(a, &p.subst_self(&r))?);
        }
        let ret = sig.ret.subst_self(&r);
        if let Some(t) = expected {
            if !self.inf.unify(t, &ret) {
                return err(ErrorKind::TypeMismatch, e.pos);
            }
        }
        Ok((ir::Expr::CallMethod(tr, midx as u16, Box::new(rir), irs), ret))
    }

    // ---------------------------------------------------------- operators

    fn unary(&mut self, op: UnOp, x: &Expr) -> Res<(ir::Expr, Type)> {
        match op {
            UnOp::Neg => {
                let (xi, t) = self.infer(x)?;
                let t = self.inf.shallow(&t);
                let n = match t {
                    Type::Int => Num::I,
                    Type::Float => Num::F,
                    _ => return err(ErrorKind::TypeMismatch, x.pos),
                };
                Ok((ir::Expr::Neg(n, Box::new(xi)), t))
            }
            UnOp::Not => {
                let xi = self.check(x, &Type::Bool)?;
                Ok((ir::Expr::Not(Box::new(xi)), Type::Bool))
            }
            UnOp::BitNot => {
                let xi = self.check(x, &Type::Int)?;
                Ok((ir::Expr::BitNot(Box::new(xi)), Type::Int))
            }
        }
    }

    fn binary(&mut self, op: BinOp, l: &Expr, r: &Expr) -> Res<(ir::Expr, Type)> {
        match op {
            BinOp::Add | BinOp::Sub | BinOp::Mul | BinOp::Div | BinOp::Rem => {
                let (li, lt) = self.infer(l)?;
                let lt = self.inf.shallow(&lt);
                let num = match lt {
                    Type::Int => Num::I,
                    Type::Float => Num::F,
                    _ => return err(ErrorKind::TypeMismatch, l.pos),
                };
                if op == BinOp::Rem && num == Num::F {
                    return err(ErrorKind::TypeMismatch, l.pos);
                }
                let ri = self.check(r, &lt)?;
                let a = match op {
                    BinOp::Add => Arith::Add,
                    BinOp::Sub => Arith::Sub,
                    BinOp::Mul => Arith::Mul,
                    BinOp::Div => Arith::Div,
                    _ => Arith::Rem,
                };
                Ok((ir::Expr::Arith(a, num, Box::new(li), Box::new(ri)), lt))
            }
            BinOp::Concat => {
                let (li, lt) = self.infer(l)?;
                let lt = self.inf.shallow(&lt);
                if !matches!(lt, Type::Str | Type::List(_)) {
                    return err(ErrorKind::TypeMismatch, l.pos);
                }
                let ri = self.check(r, &lt)?;
                Ok((ir::Expr::Concat(Box::new(li), Box::new(ri)), self.inf.deep(&lt)))
            }
            BinOp::BitAnd | BinOp::BitOr | BinOp::BitXor | BinOp::Shl | BinOp::Shr => {
                let li = self.check(l, &Type::Int)?;
                let ri = self.check(r, &Type::Int)?;
                let b = match op {
                    BinOp::BitAnd => Bit::And,
                    BinOp::BitOr => Bit::Or,
                    BinOp::BitXor => Bit::Xor,
                    BinOp::Shl => Bit::Shl,
                    _ => Bit::Shr,
                };
                Ok((ir::Expr::Bit(b, Box::new(li), Box::new(ri)), Type::Int))
            }
            BinOp::Lt | BinOp::Le | BinOp::Gt | BinOp::Ge => {
                let (li, lt) = self.infer(l)?;
                if !self.holds(&lt, Bound::Ord) {
                    return err(ErrorKind::NotOrd, l.pos);
                }
                let ri = self.check(r, &lt)?;
                let c = match op {
                    BinOp::Lt => Cmp::Lt,
                    BinOp::Le => Cmp::Le,
                    BinOp::Gt => Cmp::Gt,
                    _ => Cmp::Ge,
                };
                Ok((ir::Expr::Cmp(c, Box::new(li), Box::new(ri)), Type::Bool))
            }
            BinOp::Eq | BinOp::Ne => {
                let (li, lt) = self.infer(l)?;
                if !self.holds(&lt, Bound::Eq) {
                    return err(ErrorKind::NotEq, l.pos);
                }
                let ri = self.check(r, &lt)?;
                let c = if op == BinOp::Eq { Cmp::Eq } else { Cmp::Ne };
                Ok((ir::Expr::Cmp(c, Box::new(li), Box::new(ri)), Type::Bool))
            }
            BinOp::And | BinOp::Or => {
                let li = self.check(l, &Type::Bool)?;
                let ri = self.check(r, &Type::Bool)?;
                let x = if op == BinOp::And {
                    ir::Expr::And(Box::new(li), Box::new(ri))
                } else {
                    ir::Expr::Or(Box::new(li), Box::new(ri))
                };
                Ok((x, Type::Bool))
            }
        }
    }

    fn index(&mut self, a: &Expr, i: &Expr) -> Res<(ir::Expr, Type)> {
        let (ai, at) = self.infer(a)?;
        match self.inf.shallow(&at) {
            Type::List(t) => {
                let ii = self.check(i, &Type::Int)?;
                Ok((ir::Expr::Index(Box::new(ai), Box::new(ii)), (*t).clone()))
            }
            Type::Str => {
                let ii = self.check(i, &Type::Int)?;
                Ok((ir::Expr::Index(Box::new(ai), Box::new(ii)), Type::Char))
            }
            Type::Map(k, v) => {
                let ii = self.check(i, &k)?;
                Ok((ir::Expr::Index(Box::new(ai), Box::new(ii)), (*v).clone()))
            }
            _ => err(ErrorKind::NotIndexable, a.pos),
        }
    }

    fn field(&mut self, x: &Expr, f: &Ident) -> Res<(ir::Expr, Type)> {
        let (xi, xt) = self.infer(x)?;
        let (d, args) = match self.inf.shallow(&xt) {
            Type::Named(d, args) => (d, args),
            _ => return err(ErrorKind::NotStruct, x.pos),
        };
        let fields = match self.prog.struct_fields(d) {
            Some(fs) => fs,
            None => return err(ErrorKind::NotStruct, x.pos),
        };
        match fields.iter().position(|(n, _)| *n == f.name) {
            Some(i) => {
                let t = fields[i].1.subst_params(&args);
                Ok((ir::Expr::Field(Box::new(xi), i), self.inf.deep(&t)))
            }
            None => err(ErrorKind::UnknownField, f.pos),
        }
    }

    fn struct_lit(
        &mut self,
        path: &ast::Path,
        fields: &[(Ident, Expr)],
        expected: Option<&Type>,
    ) -> Res<(ir::Expr, Type)> {
        let prog = self.prog;
        let d = prog.resolve_type_path(self.module, path)?;
        let sfields = match prog.struct_fields(d) {
            Some(f) => f,
            None => return err(ErrorKind::NotStruct, path.pos()),
        };
        let ntp = prog.decls[d as usize].tparams.len();
        self.inf.push_scope();
        let vars: Vec<Type> = (0..ntp).map(|_| self.inf.fresh()).collect();
        let sty = Type::named(d, vars.clone());
        if let Some(t) = expected {
            if !self.inf.unify(&sty, t) {
                return err(ErrorKind::TypeMismatch, path.pos());
            }
        }
        let mut seen: Vec<&str> = Vec::new();
        for (fname, _) in fields {
            if seen.contains(&fname.name.as_str()) {
                return err(ErrorKind::DupField, fname.pos);
            }
            seen.push(&fname.name);
            if !sfields.iter().any(|(n, _)| *n == fname.name) {
                return err(ErrorKind::UnknownField, fname.pos);
            }
        }
        let mut vals: Vec<Option<ir::Expr>> = (0..sfields.len()).map(|_| None).collect();
        for (idx, (fname, fty)) in sfields.iter().enumerate() {
            match fields.iter().find(|(n, _)| n.name == *fname) {
                Some((_, ex)) => {
                    let ft = fty.subst_params(&vars);
                    vals[idx] = Some(self.check(ex, &ft)?);
                }
                None => return err(ErrorKind::MissingField, path.pos()),
            }
        }
        let scope_vars = self.inf.pop_scope();
        for v in scope_vars {
            if !self.inf.is_ground(&Type::Var(v)) {
                return err(ErrorKind::CannotInfer, path.pos());
            }
        }
        let mut written = Vec::new();
        for (fname, _) in fields {
            let idx = sfields.iter().position(|(n, _)| *n == fname.name).unwrap();
            written.push((idx, vals[idx].take().unwrap()));
        }
        Ok((ir::Expr::MakeStruct(d, written, sfields.len()), self.inf.deep(&sty)))
    }

    // -------------------------------------------------- if / match / lambda

    fn if_expr(
        &mut self,
        e: &Expr,
        cond: &Expr,
        then: &ast::Block,
        els: Option<&Expr>,
        expected: Option<&Type>,
    ) -> Res<(ir::Expr, Type)> {
        let c = self.check(cond, &Type::Bool)?;
        match (els, expected) {
            (None, Some(t)) => {
                if !self.inf.unify(t, &Type::Unit) {
                    return err(ErrorKind::TypeMismatch, e.pos);
                }
                let b = self.block_check(then, &Type::Unit)?;
                Ok((ir::Expr::If(Box::new(c), Box::new(b), None), Type::Unit))
            }
            (None, None) => {
                let b = self.block_check(then, &Type::Unit)?;
                Ok((ir::Expr::If(Box::new(c), Box::new(b), None), Type::Unit))
            }
            (Some(el), Some(t)) => {
                let b = self.block_check(then, t)?;
                let ei = self.check(el, t)?;
                Ok((ir::Expr::If(Box::new(c), Box::new(b), Some(Box::new(ei))), t.clone()))
            }
            (Some(el), None) => {
                if !diverges_block(then) {
                    let (b, t) = self.block_infer(then)?;
                    let ei = self.check(el, &t)?;
                    Ok((
                        ir::Expr::If(Box::new(c), Box::new(b), Some(Box::new(ei))),
                        self.inf.deep(&t),
                    ))
                } else {
                    let (b, _) = self.block_infer(then)?;
                    let (ei, t) = self.infer(el)?;
                    let t = if diverges_expr(el) { Type::Unit } else { t };
                    Ok((ir::Expr::If(Box::new(c), Box::new(b), Some(Box::new(ei))), t))
                }
            }
        }
    }

    fn match_expr(
        &mut self,
        e: &Expr,
        scrut: &Expr,
        arms: &[ast::Arm],
        expected: Option<&Type>,
    ) -> Res<(ir::Expr, Type)> {
        let (sir, st) = self.infer(scrut)?;
        let st = self.inf.deep(&st);
        if arms.is_empty() {
            return err(ErrorKind::NonExhaustive, e.pos);
        }
        let mut result: Option<Type> = expected.cloned();
        let mut iarms = Vec::new();
        for arm in arms {
            self.push_scope();
            let mut names = Vec::new();
            let pat = self.check_pat(&arm.pat, &st, &mut names)?;
            let guard = match &arm.guard {
                Some(g) => Some(self.check(g, &Type::Bool)?),
                None => None,
            };
            let body = match &result {
                Some(r) => {
                    let r = r.clone();
                    self.check(&arm.body, &r)?
                }
                None => {
                    if diverges_expr(&arm.body) {
                        self.infer(&arm.body)?.0
                    } else {
                        let (b, t) = self.infer(&arm.body)?;
                        result = Some(t);
                        b
                    }
                }
            };
            self.pop_scope();
            iarms.push(ir::Arm { pat, guard, body });
        }
        let mut rows: Vec<Vec<exhaust::P>> = Vec::new();
        let tys = vec![st.clone()];
        for (i, arm) in iarms.iter().enumerate() {
            let q = vec![super::pat::to_xpat(&arm.pat)];
            if !exhaust::useful(self.prog, &rows, &q, &tys) {
                return err(ErrorKind::Unreachable, arms[i].pat.pos);
            }
            if arm.guard.is_none() {
                rows.push(q);
            }
        }
        if exhaust::useful(self.prog, &rows, &vec![exhaust::P::Wild], &tys) {
            return err(ErrorKind::NonExhaustive, e.pos);
        }
        let ty = match result {
            Some(r) => self.inf.deep(&r),
            None => Type::Unit,
        };
        Ok((ir::Expr::Match(Box::new(sir), iarms), ty))
    }

    fn lambda(
        &mut self,
        e: &Expr,
        lam: &ast::Lambda,
        expected: Option<&Type>,
    ) -> Res<(ir::Expr, Type)> {
        let n = lam.params.len();
        // parameter types and return type
        let mut ret_ty: Option<Type> = None;
        let mut param_tys: Vec<Type> = Vec::new();
        if let Some(t) = expected {
            let t = self.inf.shallow(t);
            match &t {
                Type::Fn(ps, r) => {
                    if ps.len() != n {
                        return err(ErrorKind::TypeMismatch, e.pos);
                    }
                    param_tys = ps.to_vec();
                    ret_ty = Some((**r).clone());
                }
                Type::Var(_) => {
                    let ps: Vec<Type> = (0..n).map(|_| self.inf.fresh()).collect();
                    let r = self.inf.fresh();
                    self.inf.unify(&t, &Type::func(ps.clone(), r.clone()));
                    param_tys = ps;
                    ret_ty = Some(r);
                }
                _ => return err(ErrorKind::TypeMismatch, e.pos),
            }
        }
        let checking = expected.is_some();
        let mut final_params: Vec<Type> = Vec::new();
        for (i, p) in lam.params.iter().enumerate() {
            match &p.ty {
                Some(a) => {
                    let at = self.resolve_written(a)?;
                    if checking {
                        if !self.inf.unify(&param_tys[i], &at) {
                            return err(ErrorKind::TypeMismatch, a.pos);
                        }
                        final_params.push(param_tys[i].clone());
                    } else {
                        final_params.push(at);
                    }
                }
                None => {
                    if !checking || matches!(self.inf.shallow(&param_tys[i]), Type::Var(_)) {
                        return err(ErrorKind::CannotInfer, p.name.pos);
                    }
                    final_params.push(param_tys[i].clone());
                }
            }
        }
        if let Some(rt) = &lam.ret {
            let declared = self.resolve_written(rt)?;
            match &ret_ty {
                Some(r) => {
                    if !self.inf.unify(r, &declared) {
                        return err(ErrorKind::TypeMismatch, rt.pos);
                    }
                }
                None => ret_ty = Some(declared),
            }
        }
        // duplicate parameter names
        for (i, p) in lam.params.iter().enumerate() {
            if lam.params[..i].iter().any(|q| q.name.name == p.name.name) {
                return err(ErrorKind::DupName, p.name.pos);
            }
        }
        // the body, as a new function
        self.fstack.push(FnCtx {
            scopes: Vec::new(),
            next_slot: 0,
            max_slot: 0,
            upvals: Vec::new(),
            ret: ret_ty.clone(),
            loop_depth: 0,
        });
        self.push_scope();
        for (p, t) in lam.params.iter().zip(final_params.iter()) {
            self.declare(&p.name.name, false, t.clone());
        }
        let body_res = self.lambda_body(e, lam, ret_ty.as_ref());
        let (block, result_ty) = match body_res {
            Ok(x) => x,
            Err(d) => {
                self.fstack.pop();
                return Err(d);
            }
        };
        let ctx = self.fstack.pop().unwrap();
        let captures: Vec<ir::VarRef> = ctx.upvals.iter().map(|u| u.parent).collect();
        let func = ir::Func {
            name: "<lambda>".to_string(),
            nparams: n,
            nslots: ctx.max_slot,
            nupvals: ctx.upvals.len(),
            body: block,
        };
        let id = self.funcs.len() as FnId;
        self.funcs.push(Some(func));
        let fty = Type::func(
            final_params.iter().map(|t| self.inf.deep(t)).collect(),
            self.inf.deep(&result_ty),
        );
        Ok((ir::Expr::Lambda(id, captures), fty))
    }

    fn lambda_body(
        &mut self,
        e: &Expr,
        lam: &ast::Lambda,
        ret: Option<&Type>,
    ) -> Res<(ir::Block, Type)> {
        match (&lam.body.kind, ret) {
            (ExprKind::Block(b), Some(r)) => {
                let blk = self.fn_body(b, r, e.pos)?;
                Ok((blk, r.clone()))
            }
            (ExprKind::Block(b), None) => {
                let mut stmts = Vec::new();
                for s in &b.stmts {
                    stmts.push(self.stmt(s)?);
                }
                let mut tail = None;
                let mut ty = Type::Unit;
                if let Some(t) = &b.tail {
                    let (i, t) = self.infer(t)?;
                    tail = Some(i);
                    ty = t;
                }
                Ok((ir::Block { stmts, tail }, ty))
            }
            (_, Some(r)) => {
                let i = self.check(&lam.body, r)?;
                Ok((ir::Block { stmts: vec![], tail: Some(i) }, r.clone()))
            }
            (_, None) => {
                let (i, t) = self.infer(&lam.body)?;
                Ok((ir::Block { stmts: vec![], tail: Some(i) }, t))
            }
        }
    }
}
