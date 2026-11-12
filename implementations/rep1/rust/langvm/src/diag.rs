//! Diagnostics: source positions, error kinds and the single-line error report.

use std::fmt;

/// A position in a module: 1-based line and column (columns count Unicode
/// scalar values).
#[derive(Copy, Clone, PartialEq, Eq, Debug, Default, PartialOrd, Ord, Hash)]
pub struct Pos {
    /// 1-based line number (module-local, except for `bad-module`/`dup-module`).
    pub line: u32,
    /// 1-based column.
    pub col: u32,
}

impl Pos {
    /// Creates a position.
    pub fn new(line: u32, col: u32) -> Pos {
        Pos { line, col }
    }
}

macro_rules! error_kinds {
    ($($variant:ident => $text:literal,)*) => {
        /// Every compile-time diagnostic kind defined by the language.
        #[derive(Copy, Clone, PartialEq, Eq, Debug, Hash)]
        pub enum ErrorKind {
            $(
                #[doc = $text]
                $variant,
            )*
        }

        impl ErrorKind {
            /// The kind's spelling in the diagnostic line.
            pub fn as_str(self) -> &'static str {
                match self {
                    $(ErrorKind::$variant => $text,)*
                }
            }

            /// All kinds, in declaration order.
            pub const ALL: &'static [ErrorKind] = &[$(ErrorKind::$variant,)*];
        }
    };
}

error_kinds! {
    BadModule => "bad-module",
    DupModule => "dup-module",
    BadToken => "bad-token",
    IntRange => "int-range",
    BadEscape => "bad-escape",
    Unterminated => "unterminated",
    Parse => "parse",
    ReservedName => "reserved-name",
    DupName => "dup-name",
    UnknownModule => "unknown-module",
    UnknownType => "unknown-type",
    UnknownTrait => "unknown-trait",
    NotPublic => "not-public",
    ArityType => "arity-type",
    BadArity => "bad-arity",
    BadKeyType => "bad-key-type",
    SelfOutside => "self-outside",
    BuiltinTraitImpl => "builtin-trait-impl",
    BadImplHead => "bad-impl-head",
    UnusedParam => "unused-param",
    DupImpl => "dup-impl",
    MissingMethod => "missing-method",
    ExtraMethod => "extra-method",
    SigMismatch => "sig-mismatch",
    NoMain => "no-main",
    UnknownName => "unknown-name",
    TypeMismatch => "type-mismatch",
    Arity => "arity",
    NotCallable => "not-callable",
    NotStruct => "not-struct",
    UnknownField => "unknown-field",
    MissingField => "missing-field",
    DupField => "dup-field",
    NotIndexable => "not-indexable",
    NotIterable => "not-iterable",
    NoMethod => "no-method",
    AmbigMethod => "ambig-method",
    UnsatisfiedBound => "unsatisfied-bound",
    NotEq => "not-eq",
    NotOrd => "not-ord",
    CannotInfer => "cannot-infer",
    NonExhaustive => "non-exhaustive",
    Unreachable => "unreachable",
    MissingReturn => "missing-return",
    BadValueRef => "bad-value-ref",
    BadPattern => "bad-pattern",
    RefutablePattern => "refutable-pattern",
    BreakOutside => "break-outside",
    AssignImmutable => "assign-immutable",
    AssignCaptured => "assign-captured",
    BadTarget => "bad-target",
}

/// A compile-time diagnostic: a kind and the position it is reported at.
#[derive(Copy, Clone, PartialEq, Eq, Debug)]
pub struct Diag {
    /// What went wrong.
    pub kind: ErrorKind,
    /// Where.
    pub pos: Pos,
}

impl Diag {
    /// Creates a diagnostic.
    pub fn new(kind: ErrorKind, pos: Pos) -> Diag {
        Diag { kind, pos }
    }
}

impl fmt::Display for Diag {
    /// Formats as `error: <kind> at <line>:<col>` (without a trailing newline).
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "error: {} at {}:{}", self.kind.as_str(), self.pos.line, self.pos.col)
    }
}

impl std::error::Error for Diag {}

/// Result alias used throughout the compiler.
pub type Res<T> = Result<T, Diag>;

/// Shorthand for building an `Err(Diag)`.
pub fn err<T>(kind: ErrorKind, pos: Pos) -> Res<T> {
    Err(Diag::new(kind, pos))
}
