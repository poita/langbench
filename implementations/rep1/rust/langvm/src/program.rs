//! Program-wide declaration tables, name lookup, type resolution and trait
//! satisfaction.

use crate::ast::{self, TypeExpr, TypeKind};
use crate::builtins::Builtin;
use crate::diag::{err, ErrorKind, Pos, Res};
use crate::types::*;
use std::collections::HashMap;

/// Pseudo module index meaning "the prelude only" (used for built-in signatures).
pub const NO_MODULE: usize = usize::MAX;

/// Head-constructor number of a type (used to key impls and dispatch).
pub type Ctor = u32;
/// Head constructor of `Int`.
pub const CTOR_INT: Ctor = 0;
/// Head constructor of `Float`.
pub const CTOR_FLOAT: Ctor = 1;
/// Head constructor of `Bool`.
pub const CTOR_BOOL: Ctor = 2;
/// Head constructor of `Char`.
pub const CTOR_CHAR: Ctor = 3;
/// Head constructor of `Str`.
pub const CTOR_STR: Ctor = 4;
/// Head constructor of `Unit`.
pub const CTOR_UNIT: Ctor = 5;
/// Head constructor of lists.
pub const CTOR_LIST: Ctor = 6;
/// Head constructor of maps.
pub const CTOR_MAP: Ctor = 7;
/// First head-constructor number used for struct/enum declarations.
pub const CTOR_DECL_BASE: Ctor = 8;

/// What a name in a module's values namespace refers to.
#[derive(Copy, Clone, Debug)]
pub enum ValueItem {
    /// A user function.
    Func(FnId),
    /// A variant: enum declaration and variant index.
    Variant(DeclId, u32),
}

/// What a prelude value name refers to.
#[derive(Copy, Clone, Debug)]
pub enum PreludeValue {
    /// A built-in function.
    Builtin(Builtin),
    /// A variant of the prelude `Option`/`Result`.
    Variant(DeclId, u32),
}

/// The four namespaces of one module.
#[derive(Default, Debug)]
pub struct ModuleData {
    /// The module's name.
    pub name: String,
    /// Struct and enum names.
    pub types: HashMap<String, DeclId>,
    /// Trait names.
    pub traits: HashMap<String, TraitId>,
    /// Function and variant names.
    pub values: HashMap<String, ValueItem>,
    /// Imports: bound name to module index.
    pub imports: HashMap<String, usize>,
    /// Imports ordered by bound name (ASCII order).
    pub imports_sorted: Vec<(String, usize)>,
    /// Traits visible here, deduplicated, own first.
    pub visible_traits: Vec<TraitId>,
}

/// A struct or enum declaration.
#[derive(Debug, Clone)]
pub struct TypeDecl {
    /// Name.
    pub name: String,
    /// Declaring module (`NO_MODULE` for the prelude).
    pub module: usize,
    /// Whether `pub`.
    pub is_pub: bool,
    /// Type parameter names.
    pub tparams: Vec<String>,
    /// Fields or variants.
    pub kind: DeclKind,
}

/// The shape of a declaration.
#[derive(Debug, Clone)]
pub enum DeclKind {
    /// A struct: ordered fields.
    Struct(Vec<(String, Type)>),
    /// An enum: ordered variants.
    Enum(Vec<VariantInfo>),
}

/// A resolved enum variant.
#[derive(Debug, Clone)]
pub struct VariantInfo {
    /// Variant name.
    pub name: String,
    /// Payload types.
    pub payload: Vec<Type>,
}

/// A function signature.
#[derive(Debug, Clone, Default)]
pub struct FnSig {
    /// Type parameters with bounds.
    pub tparams: Vec<TParam>,
    /// Parameter types.
    pub params: Vec<Type>,
    /// Return type.
    pub ret: Option<Type>,
}

impl FnSig {
    /// The return type (`Unit` when unset).
    pub fn ret_ty(&self) -> Type {
        self.ret.clone().unwrap_or(Type::Unit)
    }
}

/// A user function, method or default body.
#[derive(Debug, Clone)]
pub struct FnInfo {
    /// Name (for diagnostics and debugging).
    pub name: String,
    /// Declaring module.
    pub module: usize,
    /// Whether `pub`.
    pub is_pub: bool,
    /// Resolved signature.
    pub sig: FnSig,
}

/// A trait method signature.
#[derive(Debug, Clone)]
pub struct MethodInfo {
    /// Method name.
    pub name: String,
    /// Parameter types after `self`, with `Self` as `Param(SELF_PARAM)`.
    pub params: Vec<Type>,
    /// Return type.
    pub ret: Type,
    /// Function id of the default body, if any.
    pub default: Option<FnId>,
}

/// A trait declaration.
#[derive(Debug, Clone)]
pub struct TraitInfo {
    /// Name.
    pub name: String,
    /// Declaring module.
    pub module: usize,
    /// Whether `pub`.
    pub is_pub: bool,
    /// Methods in declaration order.
    pub methods: Vec<MethodInfo>,
}

/// An impl declaration.
#[derive(Debug, Clone)]
pub struct ImplInfo {
    /// The implemented trait (set in pass 3.4).
    pub trait_id: TraitId,
    /// The impl's module.
    pub module: usize,
    /// Impl type parameters.
    pub tparams: Vec<TParam>,
    /// The head type.
    pub head: Type,
    /// Function ids of the impl's own methods, in source order.
    pub own: Vec<FnId>,
    /// Final method table by trait method index (own method or default).
    pub table: Vec<Option<FnId>>,
}

/// All declarations of a program after pass 3.
#[derive(Debug)]
pub struct Program {
    /// Per-module namespaces.
    pub modules: Vec<ModuleData>,
    /// Struct and enum declarations; 0 is `Option`, 1 is `Result`.
    pub decls: Vec<TypeDecl>,
    /// Trait declarations.
    pub traits: Vec<TraitInfo>,
    /// Functions, impl methods and default bodies.
    pub fns: Vec<FnInfo>,
    /// Impl declarations.
    pub impls: Vec<ImplInfo>,
    /// Impl registry keyed by (trait, head constructor).
    pub impl_map: HashMap<(TraitId, Ctor), usize>,
    /// Built-in function signatures, indexed by `Builtin as usize`.
    pub builtin_sigs: Vec<FnSig>,
    /// The prelude's value namespace.
    pub prelude_values: HashMap<&'static str, PreludeValue>,
    /// Index of `main`'s function.
    pub main_fn: FnId,
}

/// Declaration id of the prelude `Option`.
pub const OPTION_DECL: DeclId = 0;
/// Declaration id of the prelude `Result`.
pub const RESULT_DECL: DeclId = 1;

/// The view of type-parameter bounds needed to decide trait satisfaction.
#[derive(Copy, Clone)]
pub struct TyEnv<'a> {
    /// Type parameters in scope.
    pub tparams: &'a [TParam],
    /// Bounds of `Self` (only non-empty in a trait default body).
    pub self_bounds: &'a [Bound],
}

impl<'a> TyEnv<'a> {
    /// An environment with no parameters.
    pub const EMPTY: TyEnv<'static> = TyEnv { tparams: &[], self_bounds: &[] };

    fn bounds_of(&self, p: u32) -> &'a [Bound] {
        if p == SELF_PARAM {
            self.self_bounds
        } else {
            self.tparams.get(p as usize).map_or(&[][..], |t| &t.bounds[..])
        }
    }
}

/// Context for resolving a written type.
#[derive(Copy, Clone)]
pub struct TyCx<'a> {
    /// The module the text is in (`NO_MODULE` for the prelude).
    pub module: usize,
    /// Type parameters in scope.
    pub tparams: &'a [TParam],
    /// Bounds of `Self`.
    pub self_bounds: &'a [Bound],
    /// What `Self` means here (`None` outside traits and impls).
    pub self_ty: Option<&'a Type>,
}

impl<'a> TyCx<'a> {
    /// The trait-bound environment of this context.
    pub fn env(&self) -> TyEnv<'a> {
        TyEnv { tparams: self.tparams, self_bounds: self.self_bounds }
    }
}

/// The type of a primitive type name.
pub fn primitive(name: &str) -> Option<Type> {
    Some(match name {
        "Int" => Type::Int,
        "Float" => Type::Float,
        "Bool" => Type::Bool,
        "Char" => Type::Char,
        "Str" => Type::Str,
        "Unit" => Type::Unit,
        _ => return None,
    })
}

impl Program {
    /// Builds the prelude: `Option`, `Result`, and the built-in signatures.
    pub fn new() -> Program {
        let mut prog = Program {
            modules: Vec::new(),
            decls: Vec::new(),
            traits: Vec::new(),
            fns: Vec::new(),
            impls: Vec::new(),
            impl_map: HashMap::new(),
            builtin_sigs: Vec::new(),
            prelude_values: HashMap::new(),
            main_fn: 0,
        };
        let v = |n: &str, p: Vec<Type>| VariantInfo { name: n.to_string(), payload: p };
        prog.decls.push(TypeDecl {
            name: "Option".into(),
            module: NO_MODULE,
            is_pub: true,
            tparams: vec!["T".into()],
            kind: DeclKind::Enum(vec![v("Some", vec![Type::Param(0)]), v("None", vec![])]),
        });
        prog.decls.push(TypeDecl {
            name: "Result".into(),
            module: NO_MODULE,
            is_pub: true,
            tparams: vec!["T".into(), "E".into()],
            kind: DeclKind::Enum(vec![
                v("Ok", vec![Type::Param(0)]),
                v("Err", vec![Type::Param(1)]),
            ]),
        });
        prog.prelude_values.insert("Some", PreludeValue::Variant(OPTION_DECL, 0));
        prog.prelude_values.insert("None", PreludeValue::Variant(OPTION_DECL, 1));
        prog.prelude_values.insert("Ok", PreludeValue::Variant(RESULT_DECL, 0));
        prog.prelude_values.insert("Err", PreludeValue::Variant(RESULT_DECL, 1));
        for &b in Builtin::ALL {
            prog.prelude_values.insert(b.name(), PreludeValue::Builtin(b));
            let src = format!("fn {} {{}}", b.signature());
            let toks = crate::lexer::lex(&src).expect("builtin signature lexes");
            let m = crate::parser::parse_module(toks, Pos::new(1, 1)).expect("builtin signature parses");
            let f = match &m.items[0] {
                ast::Item::Fn(f) => f.clone(),
                _ => unreachable!(),
            };
            let sig = crate::resolve::resolve_fn_sig(&prog, &f, NO_MODULE).expect("builtin signature resolves");
            prog.builtin_sigs.push(sig);
        }
        prog
    }

    // ------------------------------------------------------------ lookup

    /// Whether a declaration named `name` is visible unqualified in `module`
    /// (module types first, then the prelude's `Option`/`Result`).
    pub fn lookup_type_name(&self, module: usize, name: &str) -> Option<DeclId> {
        if module != NO_MODULE {
            if let Some(d) = self.modules[module].types.get(name) {
                return Some(*d);
            }
        }
        match name {
            "Option" => Some(OPTION_DECL),
            "Result" => Some(RESULT_DECL),
            _ => None,
        }
    }

    /// Resolves a (possibly qualified) path in the types namespace.
    ///
    /// # Errors
    /// `unknown-type`, `not-public` or `unknown-module`.
    pub fn resolve_type_path(&self, module: usize, path: &ast::Path) -> Res<DeclId> {
        match &path.qual {
            None => self
                .lookup_type_name(module, &path.name.name)
                .ok_or(crate::diag::Diag::new(ErrorKind::UnknownType, path.name.pos)),
            Some(q) => {
                let m = self.import_of(module, &q.name);
                match m {
                    None => err(ErrorKind::UnknownModule, q.pos),
                    Some(m) => match self.modules[m].types.get(&path.name.name) {
                        None => err(ErrorKind::UnknownType, path.name.pos),
                        Some(&d) => {
                            if !self.decls[d as usize].is_pub && m != module {
                                err(ErrorKind::NotPublic, path.name.pos)
                            } else {
                                Ok(d)
                            }
                        }
                    },
                }
            }
        }
    }

    /// The module bound to `name` in `module`'s imports namespace.
    pub fn import_of(&self, module: usize, name: &str) -> Option<usize> {
        if module == NO_MODULE {
            return None;
        }
        self.modules[module].imports.get(name).copied()
    }

    /// Resolves a trait reference (bound or impl trait).
    ///
    /// # Errors
    /// `unknown-trait`, `not-public` or `unknown-module`.
    pub fn resolve_trait_ref(&self, module: usize, path: &ast::Path) -> Res<Bound> {
        match &path.qual {
            None => {
                let n = path.name.name.as_str();
                if module != NO_MODULE {
                    if let Some(t) = self.modules[module].traits.get(n) {
                        return Ok(Bound::User(*t));
                    }
                }
                match n {
                    "Eq" => Ok(Bound::Eq),
                    "Ord" => Ok(Bound::Ord),
                    "Key" => Ok(Bound::Key),
                    _ => err(ErrorKind::UnknownTrait, path.name.pos),
                }
            }
            Some(q) => match self.import_of(module, &q.name) {
                None => err(ErrorKind::UnknownModule, q.pos),
                Some(m) => match self.modules[m].traits.get(&path.name.name) {
                    None => err(ErrorKind::UnknownTrait, path.name.pos),
                    Some(&t) => {
                        if !self.traits[t as usize].is_pub && m != module {
                            err(ErrorKind::NotPublic, path.name.pos)
                        } else {
                            Ok(Bound::User(t))
                        }
                    }
                },
            },
        }
    }

    /// Finds the trait that `Name::method` refers to when `Name` is not an
    /// import (section 5.4, rule 2).
    pub fn find_visible_trait(&self, module: usize, name: &str) -> Option<Bound> {
        let md = &self.modules[module];
        if let Some(t) = md.traits.get(name) {
            return Some(Bound::User(*t));
        }
        for (_, m) in &md.imports_sorted {
            if *m == module {
                continue;
            }
            if let Some(t) = self.modules[*m].traits.get(name) {
                if self.traits[*t as usize].is_pub {
                    return Some(Bound::User(*t));
                }
            }
        }
        match name {
            "Eq" => Some(Bound::Eq),
            "Ord" => Some(Bound::Ord),
            "Key" => Some(Bound::Key),
            _ => None,
        }
    }

    // --------------------------------------------------- type resolution

    /// Resolves a written type.
    ///
    /// # Errors
    /// The type-resolution diagnostics of section 6.1.
    pub fn resolve_type(&self, te: &TypeExpr, cx: &TyCx) -> Res<Type> {
        match &te.kind {
            TypeKind::List(t) => Ok(Type::list(self.resolve_type(t, cx)?)),
            TypeKind::Map(k, v) => {
                let kt = self.resolve_type(k, cx)?;
                let vt = self.resolve_type(v, cx)?;
                if !self.holds(cx.env(), &kt, Bound::Key) {
                    return err(ErrorKind::BadKeyType, te.pos);
                }
                Ok(Type::map(kt, vt))
            }
            TypeKind::Tuple(parts) => {
                if parts.len() > 8 {
                    return err(ErrorKind::BadArity, te.pos);
                }
                let mut out = Vec::new();
                for p in parts {
                    out.push(self.resolve_type(p, cx)?);
                }
                Ok(Type::tuple(out))
            }
            TypeKind::Fn(params, ret) => {
                if params.len() > 16 {
                    return err(ErrorKind::BadArity, te.pos);
                }
                let mut ps = Vec::new();
                for p in params {
                    ps.push(self.resolve_type(p, cx)?);
                }
                let r = match ret {
                    Some(r) => self.resolve_type(r, cx)?,
                    None => Type::Unit,
                };
                Ok(Type::func(ps, r))
            }
            TypeKind::Path(path, args) => self.resolve_type_path_expr(te, path, args, cx),
        }
    }

    fn resolve_type_path_expr(
        &self,
        te: &TypeExpr,
        path: &ast::Path,
        args: &[TypeExpr],
        cx: &TyCx,
    ) -> Res<Type> {
        if path.qual.is_none() {
            let name = path.name.name.as_str();
            if let Some(i) = cx.tparams.iter().rposition(|t| t.name == name) {
                if !args.is_empty() {
                    return err(ErrorKind::ArityType, te.pos);
                }
                return Ok(Type::Param(i as u32));
            }
            if name == "Self" {
                return match cx.self_ty {
                    None => err(ErrorKind::SelfOutside, te.pos),
                    Some(t) => {
                        if !args.is_empty() {
                            err(ErrorKind::ArityType, te.pos)
                        } else {
                            Ok(t.clone())
                        }
                    }
                };
            }
            if let Some(p) = primitive(name) {
                if !args.is_empty() {
                    return err(ErrorKind::ArityType, te.pos);
                }
                return Ok(p);
            }
        }
        let d = self.resolve_type_path(cx.module, path)?;
        let decl = &self.decls[d as usize];
        if decl.tparams.len() != args.len() {
            return err(ErrorKind::ArityType, te.pos);
        }
        let mut ts = Vec::new();
        for a in args {
            ts.push(self.resolve_type(a, cx)?);
        }
        Ok(Type::named(d, ts))
    }

    // ------------------------------------------------ trait satisfaction

    /// The head constructor of `t`, if it has one.
    pub fn ctor_of(t: &Type) -> Option<Ctor> {
        Some(match t {
            Type::Int => CTOR_INT,
            Type::Float => CTOR_FLOAT,
            Type::Bool => CTOR_BOOL,
            Type::Char => CTOR_CHAR,
            Type::Str => CTOR_STR,
            Type::Unit => CTOR_UNIT,
            Type::List(_) => CTOR_LIST,
            Type::Map(..) => CTOR_MAP,
            Type::Named(d, _) => CTOR_DECL_BASE + *d,
            _ => return None,
        })
    }

    /// Whether `t` satisfies the bound `b`.
    pub fn holds(&self, env: TyEnv, t: &Type, b: Bound) -> bool {
        match b {
            Bound::Eq => self.eq_holds(env, t, &mut Vec::new()),
            Bound::Ord => match t {
                Type::Int | Type::Float | Type::Bool | Type::Char | Type::Str => true,
                Type::Param(p) => env.bounds_of(*p).contains(&Bound::Ord),
                _ => false,
            },
            Bound::Key => match t {
                Type::Int | Type::Bool | Type::Char | Type::Str => true,
                Type::Param(p) => env.bounds_of(*p).contains(&Bound::Key),
                _ => false,
            },
            Bound::User(tr) => self.user_holds(env, t, tr),
        }
    }

    fn eq_holds(&self, env: TyEnv, t: &Type, assumed: &mut Vec<DeclId>) -> bool {
        match t {
            Type::Int | Type::Float | Type::Bool | Type::Char | Type::Str | Type::Unit => true,
            Type::List(e) => self.eq_holds(env, e, assumed),
            Type::Map(_, v) => self.eq_holds(env, v, assumed),
            Type::Tuple(ts) => ts.iter().all(|x| self.eq_holds(env, x, assumed)),
            Type::Fn(..) | Type::Var(_) => false,
            Type::Param(p) => {
                let b = env.bounds_of(*p);
                b.contains(&Bound::Eq) || b.contains(&Bound::Key)
            }
            Type::Named(d, args) => {
                if assumed.contains(d) {
                    return true;
                }
                assumed.push(*d);
                let decl = &self.decls[*d as usize];
                let ok = match &decl.kind {
                    DeclKind::Struct(fields) => {
                        fields.iter().all(|(_, ft)| self.eq_holds(env, &ft.subst_params(args), assumed))
                    }
                    DeclKind::Enum(vars) => vars.iter().all(|v| {
                        v.payload.iter().all(|pt| self.eq_holds(env, &pt.subst_params(args), assumed))
                    }),
                };
                assumed.pop();
                ok
            }
        }
    }

    fn user_holds(&self, env: TyEnv, t: &Type, tr: TraitId) -> bool {
        if let Type::Param(p) = t {
            return env.bounds_of(*p).contains(&Bound::User(tr));
        }
        let ctor = match Program::ctor_of(t) {
            Some(c) => c,
            None => return false,
        };
        let imp = match self.impl_map.get(&(tr, ctor)) {
            Some(i) => &self.impls[*i],
            None => return false,
        };
        let binding = self.impl_binding(imp, t);
        for (i, tp) in imp.tparams.iter().enumerate() {
            for b in &tp.bounds {
                if !self.holds(env, &binding[i], *b) {
                    return false;
                }
            }
        }
        true
    }

    /// Matches an impl's head against `t`, returning the impl parameters' values.
    pub fn impl_binding(&self, imp: &ImplInfo, t: &Type) -> Vec<Type> {
        let mut out = vec![Type::Unit; imp.tparams.len()];
        let mut bind = |p: &Type, actual: &Type| {
            if let Type::Param(i) = p {
                if (*i as usize) < out.len() {
                    out[*i as usize] = actual.clone();
                }
            }
        };
        match (&imp.head, t) {
            (Type::List(p), Type::List(a)) => bind(p, a),
            (Type::Map(pk, pv), Type::Map(ak, av)) => {
                bind(pk, ak);
                bind(pv, av);
            }
            (Type::Named(_, ps), Type::Named(_, args)) => {
                for (p, a) in ps.iter().zip(args.iter()) {
                    bind(p, a);
                }
            }
            _ => {}
        }
        out
    }

    /// The user traits visible in `module` that declare a method `name`.
    pub fn traits_with_method(&self, module: usize, name: &str) -> Vec<TraitId> {
        self.modules[module]
            .visible_traits
            .iter()
            .copied()
            .filter(|t| self.traits[*t as usize].methods.iter().any(|m| m.name == name))
            .collect()
    }

    /// Looks up a struct's field list.
    pub fn struct_fields(&self, d: DeclId) -> Option<&Vec<(String, Type)>> {
        match &self.decls[d as usize].kind {
            DeclKind::Struct(f) => Some(f),
            _ => None,
        }
    }

    /// Looks up an enum's variants.
    pub fn enum_variants(&self, d: DeclId) -> Option<&Vec<VariantInfo>> {
        match &self.decls[d as usize].kind {
            DeclKind::Enum(v) => Some(v),
            _ => None,
        }
    }
}

impl Default for Program {
    fn default() -> Self {
        Program::new()
    }
}
