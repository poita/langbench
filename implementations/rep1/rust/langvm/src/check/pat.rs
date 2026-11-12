//! Pattern typing and irrefutability.

use super::Checker;
use crate::ast::{self, PatKind};
use crate::diag::{err, ErrorKind, Res};
use crate::exhaust::{Ctor, P};
use crate::ir;
use crate::program::{DeclKind, ValueItem, PreludeValue};
use crate::types::*;

impl<'a> Checker<'a> {
    /// Resolves a pattern constructor path in the values namespace (locals
    /// are not consulted). Returns the variant if the name is one.
    fn resolve_pat_ctor(&self, path: &ast::Path) -> Res<Option<(DeclId, u32)>> {
        let prog = self.prog;
        match &path.qual {
            None => {
                let n = path.name.name.as_str();
                if let Some(v) = prog.modules[self.module].values.get(n) {
                    return Ok(match v {
                        ValueItem::Variant(d, i) => Some((*d, *i)),
                        ValueItem::Func(_) => None,
                    });
                }
                if let Some(v) = prog.prelude_values.get(n) {
                    return Ok(match v {
                        PreludeValue::Variant(d, i) => Some((*d, *i)),
                        PreludeValue::Builtin(_) => None,
                    });
                }
                err(ErrorKind::UnknownName, path.name.pos)
            }
            Some(q) => {
                if let Some(m) = prog.import_of(self.module, &q.name) {
                    return match prog.modules[m].values.get(&path.name.name) {
                        None => err(ErrorKind::UnknownName, path.name.pos),
                        Some(ValueItem::Variant(d, i)) => {
                            if !prog.decls[*d as usize].is_pub && m != self.module {
                                err(ErrorKind::NotPublic, path.name.pos)
                            } else {
                                Ok(Some((*d, *i)))
                            }
                        }
                        Some(ValueItem::Func(f)) => {
                            if !prog.fns[*f as usize].is_pub && m != self.module {
                                err(ErrorKind::NotPublic, path.name.pos)
                            } else {
                                Ok(None)
                            }
                        }
                    };
                }
                match prog.find_visible_trait(self.module, &q.name) {
                    Some(Bound::User(t)) => {
                        if prog.traits[t as usize].methods.iter().any(|m| m.name == path.name.name) {
                            Ok(None)
                        } else {
                            err(ErrorKind::UnknownName, path.name.pos)
                        }
                    }
                    Some(_) => err(ErrorKind::UnknownName, path.name.pos),
                    None => err(ErrorKind::UnknownModule, q.pos),
                }
            }
        }
    }

    /// A bare identifier pattern names a zero-payload variant?
    fn pat_ident_variant(&self, name: &str) -> Option<(DeclId, u32)> {
        let prog = self.prog;
        let item = if let Some(v) = prog.modules[self.module].values.get(name) {
            match v {
                ValueItem::Variant(d, i) => Some((*d, *i)),
                ValueItem::Func(_) => None,
            }
        } else if let Some(PreludeValue::Variant(d, i)) = prog.prelude_values.get(name) {
            Some((*d, *i))
        } else {
            None
        };
        let (d, i) = item?;
        match &prog.decls[d as usize].kind {
            DeclKind::Enum(vs) if vs[i as usize].payload.is_empty() => Some((d, i)),
            _ => None,
        }
    }

    fn bind_name(&mut self, ident: &ast::Ident, ty: &Type, names: &mut Vec<String>) -> Res<u16> {
        if names.iter().any(|n| *n == ident.name) {
            return err(ErrorKind::DupName, ident.pos);
        }
        names.push(ident.name.clone());
        Ok(self.declare(&ident.name, false, ty.clone()))
    }

    /// Checks a pattern against the expected type, declaring its bindings in
    /// the current scope.
    pub(super) fn check_pat(
        &mut self,
        p: &ast::Pat,
        ty: &Type,
        names: &mut Vec<String>,
    ) -> Res<ir::Pat> {
        let ty = self.inf.shallow(ty);
        match &p.kind {
            PatKind::Wild => Ok(ir::Pat::Wild),
            PatKind::Ident(name) => {
                if let Some((d, v)) = self.pat_ident_variant(name) {
                    return self.variant_pat(p, d, v, &[], &ty, names);
                }
                let id = ast::Ident { name: name.clone(), pos: p.pos };
                let slot = self.bind_name(&id, &self.inf.deep(&ty), names)?;
                Ok(ir::Pat::Bind(slot))
            }
            PatKind::Int(n) => {
                if ty != Type::Int {
                    return err(ErrorKind::TypeMismatch, p.pos);
                }
                Ok(ir::Pat::Lit(ir::Const::Int(*n)))
            }
            PatKind::Float => err(ErrorKind::BadPattern, p.pos),
            PatKind::Str(s) => {
                if ty != Type::Str {
                    return err(ErrorKind::TypeMismatch, p.pos);
                }
                Ok(ir::Pat::Lit(ir::Const::Str(s.clone())))
            }
            PatKind::Char(c) => {
                if ty != Type::Char {
                    return err(ErrorKind::TypeMismatch, p.pos);
                }
                Ok(ir::Pat::Lit(ir::Const::Char(*c)))
            }
            PatKind::Bool(b) => {
                if ty != Type::Bool {
                    return err(ErrorKind::TypeMismatch, p.pos);
                }
                Ok(ir::Pat::Lit(ir::Const::Bool(*b)))
            }
            PatKind::Tuple(ps) => {
                let ts = match &ty {
                    Type::Tuple(ts) if ts.len() == ps.len() => ts.clone(),
                    _ => return err(ErrorKind::TypeMismatch, p.pos),
                };
                let mut out = Vec::new();
                for (sp, st) in ps.iter().zip(ts.iter()) {
                    out.push(self.check_pat(sp, st, names)?);
                }
                Ok(ir::Pat::Tuple(out))
            }
            PatKind::List(elems, rest) => {
                let elem = match &ty {
                    Type::List(e) => (**e).clone(),
                    _ => return err(ErrorKind::TypeMismatch, p.pos),
                };
                let mut out = Vec::new();
                for sp in elems {
                    out.push(self.check_pat(sp, &elem, names)?);
                }
                let rest_slot = match rest {
                    None => None,
                    Some(None) => Some(None),
                    Some(Some(id)) => {
                        let lt = Type::list(self.inf.deep(&elem));
                        Some(Some(self.bind_name(id, &lt, names)?))
                    }
                };
                Ok(ir::Pat::List(out, rest_slot))
            }
            PatKind::Struct(path, fields, rest) => {
                let d = self.prog.resolve_type_path(self.module, path)?;
                let sfields = match self.prog.struct_fields(d) {
                    Some(f) => f.clone(),
                    None => return err(ErrorKind::NotStruct, path.pos()),
                };
                let args = match &ty {
                    Type::Named(d2, args) if *d2 == d => args.clone(),
                    _ => return err(ErrorKind::TypeMismatch, p.pos),
                };
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
                if !*rest && fields.len() != sfields.len() {
                    return err(ErrorKind::MissingField, p.pos);
                }
                let mut out = vec![ir::Pat::Wild; sfields.len()];
                for (fname, sub) in fields {
                    let idx = sfields.iter().position(|(n, _)| *n == fname.name).unwrap();
                    let fty = sfields[idx].1.subst_params(&args);
                    out[idx] = match sub {
                        Some(sp) => self.check_pat(sp, &fty, names)?,
                        None => {
                            let slot = self.bind_name(fname, &self.inf.deep(&fty), names)?;
                            ir::Pat::Bind(slot)
                        }
                    };
                }
                Ok(ir::Pat::Struct(out))
            }
            PatKind::Variant(path, args) => {
                let (d, v) = match self.resolve_pat_ctor(path)? {
                    Some(x) => x,
                    None => return err(ErrorKind::TypeMismatch, p.pos),
                };
                let subs: &[ast::Pat] = args.as_deref().unwrap_or(&[]);
                self.variant_pat(p, d, v, subs, &ty, names)
            }
        }
    }

    fn variant_pat(
        &mut self,
        p: &ast::Pat,
        d: DeclId,
        v: u32,
        subs: &[ast::Pat],
        ty: &Type,
        names: &mut Vec<String>,
    ) -> Res<ir::Pat> {
        let targs = match ty {
            Type::Named(d2, args) if *d2 == d => args.clone(),
            _ => return err(ErrorKind::TypeMismatch, p.pos),
        };
        let payload = match &self.prog.decls[d as usize].kind {
            DeclKind::Enum(vs) => vs[v as usize].payload.clone(),
            _ => return err(ErrorKind::TypeMismatch, p.pos),
        };
        if payload.len() != subs.len() {
            return err(ErrorKind::Arity, p.pos);
        }
        let mut out = Vec::new();
        for (sp, pt) in subs.iter().zip(payload.iter()) {
            let st = pt.subst_params(&targs);
            out.push(self.check_pat(sp, &st, names)?);
        }
        Ok(ir::Pat::Variant(d, v as u16, out))
    }

    /// Whether a checked pattern matches every value of its type.
    pub(super) fn irrefutable(&self, p: &ir::Pat) -> bool {
        match p {
            ir::Pat::Wild | ir::Pat::Bind(_) => true,
            ir::Pat::Lit(_) => false,
            ir::Pat::Tuple(ps) | ir::Pat::Struct(ps) => ps.iter().all(|x| self.irrefutable(x)),
            ir::Pat::Variant(d, _, ps) => {
                let single = match &self.prog.decls[*d as usize].kind {
                    DeclKind::Enum(vs) => vs.len() == 1,
                    _ => false,
                };
                single && ps.iter().all(|x| self.irrefutable(x))
            }
            ir::Pat::List(ps, rest) => ps.is_empty() && rest.is_some(),
        }
    }
}

/// Converts a checked pattern into the simplified form used by the
/// usefulness algorithm.
pub fn to_xpat(p: &ir::Pat) -> P {
    match p {
        ir::Pat::Wild | ir::Pat::Bind(_) => P::Wild,
        ir::Pat::Lit(c) => P::Ctor(
            match c {
                ir::Const::Int(n) => Ctor::Int(*n),
                ir::Const::Char(c) => Ctor::Char(*c),
                ir::Const::Str(s) => Ctor::Str(s.clone()),
                ir::Const::Bool(b) => Ctor::Bool(*b),
                ir::Const::Float(_) => Ctor::Int(0),
            },
            vec![],
        ),
        ir::Pat::Variant(_, v, ps) => P::Ctor(Ctor::Variant(*v as usize), ps.iter().map(to_xpat).collect()),
        ir::Pat::Tuple(ps) => P::Ctor(Ctor::Tuple(ps.len()), ps.iter().map(to_xpat).collect()),
        ir::Pat::Struct(ps) => P::Ctor(Ctor::Struct(ps.len()), ps.iter().map(to_xpat).collect()),
        ir::Pat::List(ps, rest) => P::Ctor(
            if rest.is_some() { Ctor::ListOpen } else { Ctor::ListFixed },
            ps.iter().map(to_xpat).collect(),
        ),
    }
}
