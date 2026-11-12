//! Error values shared by every stage of a build.
//!
//! A build fails with exactly one [`Error`]: a [`ErrorKind`] plus a detail
//! byte string. [`Error::render`] produces the text that follows `error ` on
//! a log line.

use std::fmt;

/// The thirty error kinds a build can raise.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum ErrorKind {
    Parse,
    UnknownVar,
    Redefine,
    SetUndefined,
    Type,
    Arity,
    UnknownFunc,
    UnknownRule,
    UnknownCmd,
    Arg,
    IncludeMissing,
    IncludeCycle,
    BadPath,
    OutputPath,
    StepField,
    CmdShape,
    DupOutput,
    DupPhony,
    MissingInput,
    UnknownTarget,
    Cycle,
    NoDefault,
    RuleRecursion,
    DivZero,
    Interp,
    Abort,
    NoBuildFile,
    NeedPath,
    NeedMissing,
    NeedCycle,
}

impl ErrorKind {
    /// The `E_...` spelling used in the log.
    pub fn name(self) -> &'static str {
        use ErrorKind::*;
        match self {
            Parse => "E_PARSE",
            UnknownVar => "E_UNKNOWN_VAR",
            Redefine => "E_REDEFINE",
            SetUndefined => "E_SET_UNDEFINED",
            Type => "E_TYPE",
            Arity => "E_ARITY",
            UnknownFunc => "E_UNKNOWN_FUNC",
            UnknownRule => "E_UNKNOWN_RULE",
            UnknownCmd => "E_UNKNOWN_CMD",
            Arg => "E_ARG",
            IncludeMissing => "E_INCLUDE_MISSING",
            IncludeCycle => "E_INCLUDE_CYCLE",
            BadPath => "E_BAD_PATH",
            OutputPath => "E_OUTPUT_PATH",
            StepField => "E_STEP_FIELD",
            CmdShape => "E_CMD_SHAPE",
            DupOutput => "E_DUP_OUTPUT",
            DupPhony => "E_DUP_PHONY",
            MissingInput => "E_MISSING_INPUT",
            UnknownTarget => "E_UNKNOWN_TARGET",
            Cycle => "E_CYCLE",
            NoDefault => "E_NO_DEFAULT",
            RuleRecursion => "E_RULE_RECURSION",
            DivZero => "E_DIV_ZERO",
            Interp => "E_INTERP",
            Abort => "E_ABORT",
            NoBuildFile => "E_NO_BUILD_FILE",
            NeedPath => "E_NEED_PATH",
            NeedMissing => "E_NEED_MISSING",
            NeedCycle => "E_NEED_CYCLE",
        }
    }

    /// Whether the kind carries a detail on its log line.
    pub fn has_detail(self) -> bool {
        !matches!(self, ErrorKind::NoDefault | ErrorKind::DivZero)
    }
}

/// A build error: a kind and a detail (bytes, because details may echo
/// arbitrary byte strings).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Error {
    pub kind: ErrorKind,
    pub detail: Vec<u8>,
}

/// Convenient alias used throughout the crate.
pub type Result<T> = std::result::Result<T, Error>;

impl Error {
    /// Creates an error from a kind and a detail.
    pub fn new(kind: ErrorKind, detail: impl Into<Vec<u8>>) -> Error {
        Error { kind, detail: detail.into() }
    }

    /// Creates an error whose kind has no detail.
    pub fn bare(kind: ErrorKind) -> Error {
        Error { kind, detail: Vec::new() }
    }

    /// `E_TYPE <site>: expected <expected>, got <actual>`.
    pub fn type_error(site: &str, expected: &str, actual: &str) -> Error {
        Error::new(ErrorKind::Type, format!("{site}: expected {expected}, got {actual}"))
    }

    /// `E_ARG <kind> <name>: <reason>`.
    pub fn arg(kind: &str, name: &str, reason: &str) -> Error {
        Error::new(ErrorKind::Arg, format!("{kind} {name}: {reason}"))
    }

    /// The text after `error ` on a log line: kind, then detail if any.
    pub fn render(&self) -> Vec<u8> {
        let mut out = self.kind.name().as_bytes().to_vec();
        if self.kind.has_detail() {
            out.push(b' ');
            out.extend_from_slice(&self.detail);
        }
        out
    }
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", String::from_utf8_lossy(&self.render()))
    }
}

impl std::error::Error for Error {}
