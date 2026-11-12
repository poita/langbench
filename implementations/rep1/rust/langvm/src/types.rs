//! Semantic types.

use std::rc::Rc;

/// Index of a struct or enum declaration (program-wide).
pub type DeclId = u32;
/// Index of a trait declaration (program-wide).
pub type TraitId = u32;
/// Index of a compiled function (user function, method, default body, lambda).
pub type FnId = u32;

/// The pseudo type-parameter index standing for `Self` in trait declarations.
pub const SELF_PARAM: u32 = u32::MAX;

/// A semantic type.
#[derive(Clone, PartialEq, Debug)]
pub enum Type {
    /// `Int`
    Int,
    /// `Float`
    Float,
    /// `Bool`
    Bool,
    /// `Char`
    Char,
    /// `Str`
    Str,
    /// `Unit`
    Unit,
    /// `[T]`
    List(Rc<Type>),
    /// `#[K: V]`
    Map(Rc<Type>, Rc<Type>),
    /// `(A, B, ...)`
    Tuple(Rc<Vec<Type>>),
    /// `fn(A, B) -> R`
    Fn(Rc<Vec<Type>>, Rc<Type>),
    /// A struct or enum with type arguments.
    Named(DeclId, Rc<Vec<Type>>),
    /// A rigid type parameter of the enclosing declaration.
    Param(u32),
    /// An inference variable.
    Var(u32),
}

impl Type {
    /// `[t]`
    pub fn list(t: Type) -> Type {
        Type::List(Rc::new(t))
    }
    /// `#[k: v]`
    pub fn map(k: Type, v: Type) -> Type {
        Type::Map(Rc::new(k), Rc::new(v))
    }
    /// A tuple type.
    pub fn tuple(ts: Vec<Type>) -> Type {
        Type::Tuple(Rc::new(ts))
    }
    /// A function type.
    pub fn func(ps: Vec<Type>, r: Type) -> Type {
        Type::Fn(Rc::new(ps), Rc::new(r))
    }
    /// A named type.
    pub fn named(d: DeclId, args: Vec<Type>) -> Type {
        Type::Named(d, Rc::new(args))
    }

    /// Rebuilds the type, replacing each leaf for which `f` returns `Some`.
    pub fn map_leaves(&self, f: &mut dyn FnMut(&Type) -> Option<Type>) -> Type {
        if let Some(r) = f(self) {
            return r;
        }
        match self {
            Type::List(t) => Type::list(t.map_leaves(f)),
            Type::Map(k, v) => Type::map(k.map_leaves(f), v.map_leaves(f)),
            Type::Tuple(ts) => Type::tuple(ts.iter().map(|t| t.map_leaves(f)).collect()),
            Type::Fn(ps, r) => {
                Type::func(ps.iter().map(|t| t.map_leaves(f)).collect(), r.map_leaves(f))
            }
            Type::Named(d, args) => {
                Type::named(*d, args.iter().map(|t| t.map_leaves(f)).collect())
            }
            _ => self.clone(),
        }
    }

    /// Replaces `Param(i)` by `args[i]` (leaving out-of-range parameters alone).
    pub fn subst_params(&self, args: &[Type]) -> Type {
        if args.is_empty() {
            return self.clone();
        }
        self.map_leaves(&mut |t| match t {
            Type::Param(i) if (*i as usize) < args.len() => Some(args[*i as usize].clone()),
            _ => None,
        })
    }

    /// Replaces the `Self` pseudo-parameter by `r`.
    pub fn subst_self(&self, r: &Type) -> Type {
        self.map_leaves(&mut |t| match t {
            Type::Param(SELF_PARAM) => Some(r.clone()),
            _ => None,
        })
    }

    /// Whether the type mentions the inference variable `v` (without
    /// looking through bindings).
    pub fn mentions_param(&self, p: u32) -> bool {
        match self {
            Type::Param(q) => *q == p,
            Type::List(t) => t.mentions_param(p),
            Type::Map(k, v) => k.mentions_param(p) || v.mentions_param(p),
            Type::Tuple(ts) => ts.iter().any(|t| t.mentions_param(p)),
            Type::Fn(ps, r) => ps.iter().any(|t| t.mentions_param(p)) || r.mentions_param(p),
            Type::Named(_, args) => args.iter().any(|t| t.mentions_param(p)),
            _ => false,
        }
    }
}

/// A trait bound: one of the built-in traits or a user trait.
#[derive(Copy, Clone, PartialEq, Eq, Debug)]
pub enum Bound {
    /// Built-in `Eq`.
    Eq,
    /// Built-in `Ord`.
    Ord,
    /// Built-in `Key`.
    Key,
    /// A user-declared trait.
    User(TraitId),
}

/// A type parameter with its bounds.
#[derive(Clone, Debug)]
pub struct TParam {
    /// The parameter's name.
    pub name: String,
    /// Its declared bounds.
    pub bounds: Vec<Bound>,
}
