//! Pattern usefulness, exhaustiveness and reachability (section 12.4).

use crate::program::{DeclKind, Program};
use crate::types::Type;
use std::rc::Rc;

/// A constructor named by a pattern.
#[derive(Clone, Debug, PartialEq)]
pub enum Ctor {
    /// `true` / `false`.
    Bool(bool),
    /// The unit value.
    Unit,
    /// A tuple of the given arity.
    Tuple(usize),
    /// A struct with the given field count.
    Struct(usize),
    /// An enum variant.
    Variant(usize),
    /// An integer literal.
    Int(i64),
    /// A character literal.
    Char(char),
    /// A string literal.
    Str(Rc<Vec<char>>),
    /// A list of exactly this length.
    ListFixed,
    /// A list of at least this length.
    ListOpen,
}

/// A simplified pattern for the usefulness algorithm.
#[derive(Clone, Debug)]
pub enum P {
    /// Wildcard (also bindings).
    Wild,
    /// A constructor applied to sub-patterns.
    Ctor(Ctor, Vec<P>),
}

type Row = Vec<P>;

/// Computes whether `q` is useful against the matrix `rows`.
pub fn useful(prog: &Program, rows: &[Row], q: &Row, tys: &[Type]) -> bool {
    if q.is_empty() {
        return rows.is_empty();
    }
    let t1 = &tys[0];
    if let Type::List(elem) = t1 {
        return useful_list(prog, rows, q, tys, elem);
    }
    match &q[0] {
        P::Ctor(c, subs) => {
            let sub_tys = sub_types(prog, t1, c, subs.len());
            let rows2 = specialize(rows, c, subs.len());
            let mut q2: Row = subs.clone();
            q2.extend_from_slice(&q[1..]);
            let mut tys2 = sub_tys;
            tys2.extend_from_slice(&tys[1..]);
            useful(prog, &rows2, &q2, &tys2)
        }
        P::Wild => {
            let all = constructors(prog, t1);
            let mut used: Vec<&Ctor> = Vec::new();
            for r in rows {
                if let P::Ctor(c, _) = &r[0] {
                    if !used.iter().any(|u| *u == c) {
                        used.push(c);
                    }
                }
            }
            if let Some(all) = all {
                let covers = all.iter().all(|(c, _)| used.iter().any(|u| *u == c));
                if covers {
                    for (c, arity) in &all {
                        let sub_tys = sub_types(prog, t1, c, *arity);
                        let rows2 = specialize(rows, c, *arity);
                        let mut q2: Row = vec![P::Wild; *arity];
                        q2.extend_from_slice(&q[1..]);
                        let mut tys2 = sub_tys;
                        tys2.extend_from_slice(&tys[1..]);
                        if useful(prog, &rows2, &q2, &tys2) {
                            return true;
                        }
                    }
                    return false;
                }
            }
            let rows2 = default_rows(rows);
            useful(prog, &rows2, &q[1..].to_vec(), &tys[1..])
        }
    }
}

fn useful_list(prog: &Program, rows: &[Row], q: &Row, tys: &[Type], elem: &Type) -> bool {
    let mut lmax = 0usize;
    let count = |p: &P| match p {
        P::Ctor(Ctor::ListFixed, s) | P::Ctor(Ctor::ListOpen, s) => s.len(),
        _ => 0,
    };
    for r in rows {
        lmax = lmax.max(count(&r[0]));
    }
    lmax = lmax.max(count(&q[0]));
    for k in 0..=lmax + 1 {
        let admits = match &q[0] {
            P::Wild => true,
            P::Ctor(Ctor::ListFixed, s) => s.len() == k,
            P::Ctor(Ctor::ListOpen, s) => k >= s.len(),
            _ => false,
        };
        if !admits {
            continue;
        }
        let rows2: Vec<Row> = rows.iter().filter_map(|r| spec_list_row(r, k)).collect();
        let q2 = spec_list_row(q, k).unwrap_or_default();
        let mut tys2: Vec<Type> = vec![elem.clone(); k];
        tys2.extend_from_slice(&tys[1..]);
        if useful(prog, &rows2, &q2, &tys2) {
            return true;
        }
    }
    false
}

fn spec_list_row(r: &Row, k: usize) -> Option<Row> {
    match &r[0] {
        P::Wild => {
            let mut out = vec![P::Wild; k];
            out.extend_from_slice(&r[1..]);
            Some(out)
        }
        P::Ctor(Ctor::ListFixed, s) => {
            if s.len() == k {
                let mut out = s.clone();
                out.extend_from_slice(&r[1..]);
                Some(out)
            } else {
                None
            }
        }
        P::Ctor(Ctor::ListOpen, s) => {
            if s.len() <= k {
                let mut out = s.clone();
                out.extend(std::iter::repeat(P::Wild).take(k - s.len()));
                out.extend_from_slice(&r[1..]);
                Some(out)
            } else {
                None
            }
        }
        _ => None,
    }
}

fn specialize(rows: &[Row], c: &Ctor, arity: usize) -> Vec<Row> {
    let mut out = Vec::new();
    for r in rows {
        match &r[0] {
            P::Wild => {
                let mut nr = vec![P::Wild; arity];
                nr.extend_from_slice(&r[1..]);
                out.push(nr);
            }
            P::Ctor(c2, subs) => {
                if c2 == c {
                    let mut nr = subs.clone();
                    nr.extend_from_slice(&r[1..]);
                    out.push(nr);
                }
            }
        }
    }
    out
}

fn default_rows(rows: &[Row]) -> Vec<Row> {
    rows.iter()
        .filter(|r| matches!(r[0], P::Wild))
        .map(|r| r[1..].to_vec())
        .collect()
}

/// The finite constructor set of a type with arities, or `None` if infinite.
fn constructors(prog: &Program, t: &Type) -> Option<Vec<(Ctor, usize)>> {
    match t {
        Type::Bool => Some(vec![(Ctor::Bool(false), 0), (Ctor::Bool(true), 0)]),
        Type::Unit => Some(vec![(Ctor::Unit, 0)]),
        Type::Tuple(ts) => Some(vec![(Ctor::Tuple(ts.len()), ts.len())]),
        Type::Named(d, _) => match &prog.decls[*d as usize].kind {
            DeclKind::Struct(fields) => Some(vec![(Ctor::Struct(fields.len()), fields.len())]),
            DeclKind::Enum(vars) => Some(
                vars.iter().enumerate().map(|(i, v)| (Ctor::Variant(i), v.payload.len())).collect(),
            ),
        },
        _ => None,
    }
}

/// The column types after specialising a column of type `t` by `c`.
fn sub_types(prog: &Program, t: &Type, c: &Ctor, arity: usize) -> Vec<Type> {
    match (t, c) {
        (Type::Tuple(ts), Ctor::Tuple(_)) => ts.to_vec(),
        (Type::Named(d, args), Ctor::Struct(_)) => match &prog.decls[*d as usize].kind {
            DeclKind::Struct(fields) => fields.iter().map(|(_, ft)| ft.subst_params(args)).collect(),
            _ => vec![Type::Unit; arity],
        },
        (Type::Named(d, args), Ctor::Variant(i)) => match &prog.decls[*d as usize].kind {
            DeclKind::Enum(vars) => vars[*i].payload.iter().map(|pt| pt.subst_params(args)).collect(),
            _ => vec![Type::Unit; arity],
        },
        _ => vec![Type::Unit; arity],
    }
}
