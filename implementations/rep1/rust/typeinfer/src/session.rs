//! Top-level driver: the built-in environment and declaration-by-declaration
//! processing.

use std::fmt;

use crate::ast::Decl;
use crate::env::{Binding, Env};
use crate::error::{ParseError, TypeError};
use crate::infer::Infer;
use crate::parser::parse_program;
use crate::symbol::Interner;
use crate::types::Types;

/// Stack size of the helper thread used for source-level entry points.
const STACK_BYTES: usize = 1 << 30;

/// The result of checking one declaration.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DeclResult {
    /// The bound name for `let` / `let rec`; `None` for a bare expression.
    pub name: Option<String>,
    /// The rendered principal type, or the reason the declaration failed.
    pub outcome: Result<String, TypeError>,
}

impl fmt::Display for DeclResult {
    /// The CLI output line (without the trailing newline): `name : type`,
    /// `- : type`, or `error: kind`.
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match &self.outcome {
            Ok(ty) => write!(f, "{} : {}", self.name.as_deref().unwrap_or("-"), ty),
            Err(e) => write!(f, "error: {}", e),
        }
    }
}

/// A type-checking session: the top-level environment plus the type arena.
///
/// Declarations checked through the same session see the bindings made by
/// earlier successful ones.
pub struct Session {
    interner: Interner,
    types: Types,
    env: Env,
}

impl Default for Session {
    fn default() -> Self {
        Self::new()
    }
}

impl Session {
    /// A session whose environment holds exactly the built-ins
    /// (`not fst snd hd tl null length map fold`).
    pub fn new() -> Self {
        let mut s = Session { interner: Interner::new(), types: Types::new(), env: Env::default() };
        s.install_builtins();
        s
    }

    fn install_builtins(&mut self) {
        let t = &mut self.types;
        let (int, bool_) = (t.int(), t.bool());
        let (a, b) = (t.generic(), t.generic());
        let la = t.list(a);
        let lb = t.list(b);
        let ab = t.tuple(vec![a, b]);
        let a_b = t.arrow(a, b);
        let map = {
            let r = t.arrow(la, lb);
            t.arrow(a_b, r)
        };
        let fold = {
            let b_a = t.arrow(b, a);
            let f = t.arrow(a, b_a);
            let rest = {
                let r = t.arrow(lb, a);
                t.arrow(a, r)
            };
            t.arrow(f, rest)
        };
        let entries = [
            ("not", t.arrow(bool_, bool_)),
            ("fst", t.arrow(ab, a)),
            ("snd", t.arrow(ab, b)),
            ("hd", t.arrow(la, a)),
            ("tl", t.arrow(la, la)),
            ("null", t.arrow(la, bool_)),
            ("length", t.arrow(la, int)),
            ("map", map),
            ("fold", fold),
        ];
        for (name, ty) in entries {
            let sym = self.interner.intern(name);
            self.env.push(sym, Binding { ty, poly: true });
        }
    }

    /// Checks one declaration. A successful `let` / `let rec` extends the
    /// session's environment; a failure leaves it unchanged.
    ///
    /// Recurses on expression depth; for deeply nested input prefer
    /// [`Session::infer_source`].
    pub fn infer_decl(&mut self, decl: &Decl) -> DeclResult {
        let mark = self.env.mark();
        let mut inf = Infer { types: &mut self.types, env: &mut self.env, level: 0 };
        match inf.decl(decl) {
            Ok((bound, ty)) => {
                let rendered = self.types.render(ty);
                let name = bound.map(|(sym, binding)| {
                    self.env.push(sym, binding);
                    self.interner.name(sym).to_owned()
                });
                DeclResult { name, outcome: Ok(rendered) }
            }
            Err(e) => {
                self.env.truncate(mark);
                let name = match decl {
                    Decl::Let { name, .. } | Decl::LetRec { name, .. } => {
                        Some(self.interner.name(*name).to_owned())
                    }
                    Decl::Expr(_) => None,
                };
                DeclResult { name, outcome: Err(e) }
            }
        }
    }

    /// Parses `source` and checks every declaration in order.
    ///
    /// Runs on a helper thread with a large stack so that deeply nested
    /// programs do not overflow it.
    pub fn infer_source(&mut self, source: &str) -> Result<Vec<DeclResult>, ParseError> {
        std::thread::scope(|scope| {
            std::thread::Builder::new()
                .stack_size(STACK_BYTES)
                .spawn_scoped(scope, || {
                    let decls = parse_program(source, &mut self.interner)?;
                    let results = decls.iter().map(|d| self.infer_decl(d)).collect();
                    Ok(results)
                })
                .expect("failed to spawn inference thread")
                .join()
                .unwrap_or_else(|p| std::panic::resume_unwind(p))
        })
    }
}

/// Checks a whole program with a fresh [`Session`].
pub fn infer_program(source: &str) -> Result<Vec<DeclResult>, ParseError> {
    Session::new().infer_source(source)
}

/// Checks a whole program and renders it as the CLI does: one line per
/// declaration, each terminated by `\n`.
pub fn infer_to_string(source: &str) -> Result<String, ParseError> {
    let results = infer_program(source)?;
    let mut out = String::new();
    for r in &results {
        out.push_str(&r.to_string());
        out.push('\n');
    }
    Ok(out)
}
