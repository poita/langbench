//! Item declaration and resolution (pass 3 of the compiler).

use crate::ast::{self, Ident, Item};
use crate::diag::{err, ErrorKind, Pos, Res};
use crate::program::*;
use crate::types::*;
use std::collections::HashSet;

/// What an item of a module turned into.
#[derive(Copy, Clone, Debug)]
pub enum ItemRef {
    /// A `use` declaration.
    Use,
    /// A function.
    Fn(FnId),
    /// A struct.
    Struct(DeclId),
    /// An enum.
    Enum(DeclId),
    /// A trait.
    Trait(TraitId),
    /// An impl (index into `Program::impls`).
    Impl(usize),
}

/// The result of pass 3: the declaration tables plus the item mapping.
pub struct Analysis {
    /// Declaration tables.
    pub prog: Program,
    /// Parsed modules.
    pub asts: Vec<ast::Module>,
    /// For each module, one `ItemRef` per item (same order as the AST).
    pub items: Vec<Vec<ItemRef>>,
}

fn check_dups<'a>(names: impl Iterator<Item = &'a Ident>) -> Res<()> {
    let mut seen = HashSet::new();
    for n in names {
        if !seen.insert(n.name.as_str()) {
            return err(ErrorKind::DupName, n.pos);
        }
    }
    Ok(())
}

fn resolve_tparams(prog: &Program, generics: &[ast::GenParam], module: usize) -> Res<Vec<TParam>> {
    let mut out = Vec::new();
    for g in generics {
        let mut bounds = Vec::new();
        for b in &g.bounds {
            bounds.push(prog.resolve_trait_ref(module, b)?);
        }
        out.push(TParam { name: g.name.name.clone(), bounds });
    }
    Ok(out)
}

/// Resolves a function's header: bounds, parameter types, return type.
///
/// # Errors
/// The signature diagnostics of pass 3.4.
pub fn resolve_fn_sig(prog: &Program, f: &ast::FnDecl, module: usize) -> Res<FnSig> {
    let tparams = resolve_tparams(prog, &f.generics, module)?;
    let cx = TyCx { module, tparams: &tparams, self_bounds: &[], self_ty: None };
    let mut params = Vec::new();
    for p in &f.params {
        params.push(prog.resolve_type(&p.ty, &cx)?);
    }
    let ret = match &f.ret {
        Some(r) => Some(prog.resolve_type(r, &cx)?),
        None => None,
    };
    Ok(FnSig { tparams: tparams.clone(), params, ret })
}

fn resolve_method(
    prog: &Program,
    m: &ast::MethodDecl,
    cx: &TyCx,
) -> Res<(Vec<Type>, Type)> {
    let mut params = Vec::new();
    for p in &m.params {
        params.push(prog.resolve_type(&p.ty, cx)?);
    }
    let ret = match &m.ret {
        Some(r) => prog.resolve_type(r, cx)?,
        None => Type::Unit,
    };
    Ok((params, ret))
}

fn is_reserved(name: &str) -> bool {
    matches!(name, "Int" | "Float" | "Bool" | "Char" | "Str" | "Unit" | "Self")
}

/// Runs passes 3.1 to 3.6 over the parsed modules.
///
/// # Errors
/// The first diagnostic of the earliest failing sub-pass.
pub fn analyze(names: Vec<String>, asts: Vec<ast::Module>) -> Res<Analysis> {
    let mut prog = Program::new();
    let mut items: Vec<Vec<ItemRef>> = Vec::new();
    for n in &names {
        prog.modules.push(ModuleData { name: n.clone(), ..ModuleData::default() });
    }

    // ---- 3.1 declarations
    for (mi, module) in asts.iter().enumerate() {
        let mut refs = Vec::new();
        for item in &module.items {
            match item {
                Item::Use(_) => refs.push(ItemRef::Use),
                Item::Fn(f) => {
                    let id = prog.fns.len() as FnId;
                    if prog.modules[mi].values.contains_key(&f.name.name) {
                        return err(ErrorKind::DupName, f.name.pos);
                    }
                    prog.modules[mi].values.insert(f.name.name.clone(), ValueItem::Func(id));
                    prog.fns.push(FnInfo {
                        name: f.name.name.clone(),
                        module: mi,
                        is_pub: f.is_pub,
                        sig: FnSig::default(),
                    });
                    refs.push(ItemRef::Fn(id));
                }
                Item::Struct(s) => {
                    if is_reserved(&s.name.name) {
                        return err(ErrorKind::ReservedName, s.name.pos);
                    }
                    if prog.modules[mi].types.contains_key(&s.name.name) {
                        return err(ErrorKind::DupName, s.name.pos);
                    }
                    let id = prog.decls.len() as DeclId;
                    prog.modules[mi].types.insert(s.name.name.clone(), id);
                    prog.decls.push(TypeDecl {
                        name: s.name.name.clone(),
                        module: mi,
                        is_pub: s.is_pub,
                        tparams: s.generics.iter().map(|g| g.name.name.clone()).collect(),
                        kind: DeclKind::Struct(
                            s.fields.iter().map(|f| (f.name.name.clone(), Type::Unit)).collect(),
                        ),
                    });
                    refs.push(ItemRef::Struct(id));
                }
                Item::Enum(e) => {
                    if is_reserved(&e.name.name) {
                        return err(ErrorKind::ReservedName, e.name.pos);
                    }
                    if prog.modules[mi].types.contains_key(&e.name.name) {
                        return err(ErrorKind::DupName, e.name.pos);
                    }
                    let id = prog.decls.len() as DeclId;
                    prog.modules[mi].types.insert(e.name.name.clone(), id);
                    for (vi, v) in e.variants.iter().enumerate() {
                        if prog.modules[mi].values.contains_key(&v.name.name) {
                            return err(ErrorKind::DupName, v.name.pos);
                        }
                        prog.modules[mi]
                            .values
                            .insert(v.name.name.clone(), ValueItem::Variant(id, vi as u32));
                    }
                    prog.decls.push(TypeDecl {
                        name: e.name.name.clone(),
                        module: mi,
                        is_pub: e.is_pub,
                        tparams: e.generics.iter().map(|g| g.name.name.clone()).collect(),
                        kind: DeclKind::Enum(
                            e.variants
                                .iter()
                                .map(|v| VariantInfo { name: v.name.name.clone(), payload: Vec::new() })
                                .collect(),
                        ),
                    });
                    refs.push(ItemRef::Enum(id));
                }
                Item::Trait(t) => {
                    if is_reserved(&t.name.name) {
                        return err(ErrorKind::ReservedName, t.name.pos);
                    }
                    if prog.modules[mi].traits.contains_key(&t.name.name) {
                        return err(ErrorKind::DupName, t.name.pos);
                    }
                    let id = prog.traits.len() as TraitId;
                    prog.modules[mi].traits.insert(t.name.name.clone(), id);
                    let mut methods = Vec::new();
                    for m in &t.methods {
                        let default = if m.body.is_some() {
                            let fid = prog.fns.len() as FnId;
                            prog.fns.push(FnInfo {
                                name: m.name.name.clone(),
                                module: mi,
                                is_pub: false,
                                sig: FnSig::default(),
                            });
                            Some(fid)
                        } else {
                            None
                        };
                        methods.push(MethodInfo {
                            name: m.name.name.clone(),
                            params: Vec::new(),
                            ret: Type::Unit,
                            default,
                        });
                    }
                    prog.traits.push(TraitInfo {
                        name: t.name.name.clone(),
                        module: mi,
                        is_pub: t.is_pub,
                        methods,
                    });
                    refs.push(ItemRef::Trait(id));
                }
                Item::Impl(i) => {
                    let mut own = Vec::new();
                    for m in &i.methods {
                        let fid = prog.fns.len() as FnId;
                        prog.fns.push(FnInfo {
                            name: m.name.name.clone(),
                            module: mi,
                            is_pub: false,
                            sig: FnSig::default(),
                        });
                        own.push(fid);
                    }
                    let id = prog.impls.len();
                    prog.impls.push(ImplInfo {
                        trait_id: 0,
                        module: mi,
                        tparams: Vec::new(),
                        head: Type::Unit,
                        own,
                        table: Vec::new(),
                    });
                    refs.push(ItemRef::Impl(id));
                }
            }
        }
        items.push(refs);
    }

    // ---- 3.2 imports
    let module_index: std::collections::HashMap<&str, usize> =
        names.iter().enumerate().map(|(i, n)| (n.as_str(), i)).collect();
    for (mi, module) in asts.iter().enumerate() {
        for item in &module.items {
            if let Item::Use(u) = item {
                let target = match module_index.get(u.module.name.as_str()) {
                    Some(t) => *t,
                    None => return err(ErrorKind::UnknownModule, u.module.pos),
                };
                let bound = u.alias.as_ref().unwrap_or(&u.module);
                if prog.modules[mi].imports.contains_key(&bound.name) {
                    return err(ErrorKind::DupName, bound.pos);
                }
                prog.modules[mi].imports.insert(bound.name.clone(), target);
            }
        }
    }
    for mi in 0..prog.modules.len() {
        let mut sorted: Vec<(String, usize)> =
            prog.modules[mi].imports.iter().map(|(k, v)| (k.clone(), *v)).collect();
        sorted.sort();
        prog.modules[mi].imports_sorted = sorted;
        let mut visible: Vec<TraitId> = Vec::new();
        for r in &items[mi] {
            if let ItemRef::Trait(t) = r {
                visible.push(*t);
            }
        }
        for (_, m) in &prog.modules[mi].imports_sorted.clone() {
            for r in &items[*m] {
                if let ItemRef::Trait(t) = r {
                    if prog.traits[*t as usize].is_pub && !visible.contains(t) {
                        visible.push(*t);
                    }
                }
            }
        }
        prog.modules[mi].visible_traits = visible;
    }

    // ---- 3.3 internal duplicates
    for module in &asts {
        for item in &module.items {
            match item {
                Item::Use(_) => {}
                Item::Fn(f) => {
                    check_dups(f.generics.iter().map(|g| &g.name))?;
                    check_dups(f.params.iter().map(|p| &p.name))?;
                }
                Item::Struct(s) => {
                    check_dups(s.generics.iter().map(|g| &g.name))?;
                    check_dups(s.fields.iter().map(|p| &p.name))?;
                }
                Item::Enum(e) => {
                    check_dups(e.generics.iter().map(|g| &g.name))?;
                }
                Item::Trait(t) => {
                    check_dups(t.methods.iter().map(|m| &m.name))?;
                    for m in &t.methods {
                        check_dups(m.params.iter().map(|p| &p.name))?;
                    }
                }
                Item::Impl(i) => {
                    check_dups(i.generics.iter().map(|g| &g.name))?;
                    check_dups(i.methods.iter().map(|m| &m.name))?;
                    for m in &i.methods {
                        check_dups(m.params.iter().map(|p| &p.name))?;
                    }
                }
            }
        }
    }

    // ---- 3.4 signatures
    let mut impl_bounds: Vec<Bound> = vec![Bound::Eq; prog.impls.len()];
    let mut impl_sigs: Vec<Vec<(Vec<Type>, Type)>> = vec![Vec::new(); prog.impls.len()];
    for (mi, module) in asts.iter().enumerate() {
        for (k, item) in module.items.iter().enumerate() {
            match (item, items[mi][k]) {
                (Item::Fn(f), ItemRef::Fn(id)) => {
                    let sig = resolve_fn_sig(&prog, f, mi)?;
                    prog.fns[id as usize].sig = sig;
                }
                (Item::Struct(s), ItemRef::Struct(id)) => {
                    let tparams = resolve_tparams(&prog, &s.generics, mi)?;
                    let cx = TyCx { module: mi, tparams: &tparams, self_bounds: &[], self_ty: None };
                    let mut fields = Vec::new();
                    for f in &s.fields {
                        fields.push((f.name.name.clone(), prog.resolve_type(&f.ty, &cx)?));
                    }
                    prog.decls[id as usize].kind = DeclKind::Struct(fields);
                }
                (Item::Enum(e), ItemRef::Enum(id)) => {
                    let tparams = resolve_tparams(&prog, &e.generics, mi)?;
                    let cx = TyCx { module: mi, tparams: &tparams, self_bounds: &[], self_ty: None };
                    let mut vars = Vec::new();
                    for v in &e.variants {
                        let mut payload = Vec::new();
                        for t in &v.payload {
                            payload.push(prog.resolve_type(t, &cx)?);
                        }
                        vars.push(VariantInfo { name: v.name.name.clone(), payload });
                    }
                    prog.decls[id as usize].kind = DeclKind::Enum(vars);
                }
                (Item::Trait(t), ItemRef::Trait(id)) => {
                    let self_ty = Type::Param(SELF_PARAM);
                    let cx = TyCx { module: mi, tparams: &[], self_bounds: &[], self_ty: Some(&self_ty) };
                    for (j, m) in t.methods.iter().enumerate() {
                        let (params, ret) = resolve_method(&prog, m, &cx)?;
                        let mi_ = &mut prog.traits[id as usize].methods[j];
                        mi_.params = params;
                        mi_.ret = ret;
                    }
                }
                (Item::Impl(i), ItemRef::Impl(id)) => {
                    let tparams = resolve_tparams(&prog, &i.generics, mi)?;
                    let bound = prog.resolve_trait_ref(mi, &i.trait_ref)?;
                    let self_placeholder = Type::Param(SELF_PARAM);
                    let cx0 = TyCx { module: mi, tparams: &tparams, self_bounds: &[], self_ty: Some(&self_placeholder) };
                    let head = prog.resolve_type(&i.head, &cx0)?;
                    let cx = TyCx { module: mi, tparams: &tparams, self_bounds: &[], self_ty: Some(&head) };
                    let mut sigs = Vec::new();
                    for m in &i.methods {
                        sigs.push(resolve_method(&prog, m, &cx)?);
                    }
                    impl_bounds[id] = bound;
                    impl_sigs[id] = sigs;
                    prog.impls[id].tparams = tparams;
                    prog.impls[id].head = head;
                }
                _ => {}
            }
        }
    }

    // ---- 3.5 impls
    for (mi, module) in asts.iter().enumerate() {
        for (k, item) in module.items.iter().enumerate() {
            if let (Item::Impl(i), ItemRef::Impl(id)) = (item, items[mi][k]) {
                let tr = match impl_bounds[id] {
                    Bound::User(t) => t,
                    _ => return err(ErrorKind::BuiltinTraitImpl, i.pos),
                };
                let head = prog.impls[id].head.clone();
                let ntp = prog.impls[id].tparams.len();
                let distinct_params = |args: &[Type]| -> bool {
                    let mut seen = HashSet::new();
                    args.iter().all(|a| match a {
                        Type::Param(p) if (*p as usize) < ntp => seen.insert(*p),
                        _ => false,
                    })
                };
                let head_ok = match &head {
                    Type::Int | Type::Float | Type::Bool | Type::Char | Type::Str | Type::Unit => true,
                    Type::List(e) => distinct_params(&[(**e).clone()]),
                    Type::Map(k, v) => distinct_params(&[(**k).clone(), (**v).clone()]),
                    Type::Named(_, args) => distinct_params(args),
                    _ => false,
                };
                if !head_ok {
                    return err(ErrorKind::BadImplHead, i.head.pos);
                }
                for (pi, g) in i.generics.iter().enumerate() {
                    if !head.mentions_param(pi as u32) {
                        return err(ErrorKind::UnusedParam, g.name.pos);
                    }
                }
                let ctor = Program::ctor_of(&head).unwrap();
                if prog.impl_map.contains_key(&(tr, ctor)) {
                    return err(ErrorKind::DupImpl, i.pos);
                }
                prog.impl_map.insert((tr, ctor), id);
                prog.impls[id].trait_id = tr;
                let tinfo = prog.traits[tr as usize].clone();
                for tm in &tinfo.methods {
                    if tm.default.is_none() && !i.methods.iter().any(|m| m.name.name == tm.name) {
                        return err(ErrorKind::MissingMethod, i.pos);
                    }
                }
                for (j, m) in i.methods.iter().enumerate() {
                    let tm = match tinfo.methods.iter().find(|t| t.name == m.name.name) {
                        Some(t) => t,
                        None => return err(ErrorKind::ExtraMethod, m.name.pos),
                    };
                    let (params, ret) = &impl_sigs[id][j];
                    let expect_params: Vec<Type> = tm.params.iter().map(|p| p.subst_self(&head)).collect();
                    let expect_ret = tm.ret.subst_self(&head);
                    if &expect_params != params || expect_ret != *ret {
                        return err(ErrorKind::SigMismatch, m.name.pos);
                    }
                    let fid = prog.impls[id].own[j];
                    prog.fns[fid as usize].sig = FnSig {
                        tparams: prog.impls[id].tparams.clone(),
                        params: params.clone(),
                        ret: Some(ret.clone()),
                    };
                }
                let table: Vec<Option<FnId>> = tinfo
                    .methods
                    .iter()
                    .map(|tm| {
                        match i.methods.iter().position(|m| m.name.name == tm.name) {
                            Some(j) => Some(prog.impls[id].own[j]),
                            None => tm.default,
                        }
                    })
                    .collect();
                prog.impls[id].table = table;
            }
        }
    }

    // ---- 3.6 entry point
    let mut main_fn = None;
    for (mi, m) in prog.modules.iter().enumerate() {
        if m.name == "main" {
            if let Some(ValueItem::Func(f)) = m.values.get("main") {
                let info = &prog.fns[*f as usize];
                let ok = info.sig.tparams.is_empty()
                    && info.sig.params.is_empty()
                    && info.sig.ret_ty() == Type::Unit;
                if ok {
                    main_fn = Some(*f);
                }
            }
            let _ = mi;
        }
    }
    match main_fn {
        Some(f) => prog.main_fn = f,
        None => return err(ErrorKind::NoMain, Pos::new(1, 1)),
    }

    Ok(Analysis { prog, asts, items })
}
