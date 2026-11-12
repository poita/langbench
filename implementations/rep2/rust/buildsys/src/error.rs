//! The error type shared by every stage of a build.
//!
//! A build fails with exactly one [`Error`]: a [`ErrorKind`] plus a detail
//! byte string. The detail is bytes (not `String`) because KBL strings are
//! byte strings and may be echoed verbatim into the log.

use std::fmt;

/// The thirty kinds of build error. Each variant corresponds to the `E_…`
/// name returned by [`ErrorKind::code`].
#[allow(missing_docs)]
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
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
    /// The `E_…` name used in the log.
    pub const fn code(self) -> &'static str {
        match self {
            ErrorKind::Parse => "E_PARSE",
            ErrorKind::UnknownVar => "E_UNKNOWN_VAR",
            ErrorKind::Redefine => "E_REDEFINE",
            ErrorKind::SetUndefined => "E_SET_UNDEFINED",
            ErrorKind::Type => "E_TYPE",
            ErrorKind::Arity => "E_ARITY",
            ErrorKind::UnknownFunc => "E_UNKNOWN_FUNC",
            ErrorKind::UnknownRule => "E_UNKNOWN_RULE",
            ErrorKind::UnknownCmd => "E_UNKNOWN_CMD",
            ErrorKind::Arg => "E_ARG",
            ErrorKind::IncludeMissing => "E_INCLUDE_MISSING",
            ErrorKind::IncludeCycle => "E_INCLUDE_CYCLE",
            ErrorKind::BadPath => "E_BAD_PATH",
            ErrorKind::OutputPath => "E_OUTPUT_PATH",
            ErrorKind::StepField => "E_STEP_FIELD",
            ErrorKind::CmdShape => "E_CMD_SHAPE",
            ErrorKind::DupOutput => "E_DUP_OUTPUT",
            ErrorKind::DupPhony => "E_DUP_PHONY",
            ErrorKind::MissingInput => "E_MISSING_INPUT",
            ErrorKind::UnknownTarget => "E_UNKNOWN_TARGET",
            ErrorKind::Cycle => "E_CYCLE",
            ErrorKind::NoDefault => "E_NO_DEFAULT",
            ErrorKind::RuleRecursion => "E_RULE_RECURSION",
            ErrorKind::DivZero => "E_DIV_ZERO",
            ErrorKind::Interp => "E_INTERP",
            ErrorKind::Abort => "E_ABORT",
            ErrorKind::NoBuildFile => "E_NO_BUILD_FILE",
            ErrorKind::NeedPath => "E_NEED_PATH",
            ErrorKind::NeedMissing => "E_NEED_MISSING",
            ErrorKind::NeedCycle => "E_NEED_CYCLE",
        }
    }

    /// Whether the log line for this kind carries a detail.
    pub const fn has_detail(self) -> bool {
        !matches!(self, ErrorKind::NoDefault | ErrorKind::DivZero)
    }

    /// Whether the error can only arise while a command executes (after the
    /// configuration phases).
    pub const fn is_execution(self) -> bool {
        matches!(
            self,
            ErrorKind::NeedPath | ErrorKind::NeedMissing | ErrorKind::NeedCycle
        )
    }
}

/// A build error: a kind and a detail string.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Error {
    kind: ErrorKind,
    detail: Vec<u8>,
}

/// Convenience alias used throughout the crate.
pub type Result<T> = std::result::Result<T, Error>;

impl Error {
    /// Creates an error with the given detail bytes.
    pub fn new(kind: ErrorKind, detail: impl Into<Vec<u8>>) -> Error {
        Error {
            kind,
            detail: detail.into(),
        }
    }

    /// Creates an error that has no detail.
    pub fn bare(kind: ErrorKind) -> Error {
        Error::new(kind, Vec::new())
    }

    /// `E_PARSE <file>:<line>`.
    pub fn parse(file: &str, line: usize) -> Error {
        Error::new(ErrorKind::Parse, format!("{file}:{line}"))
    }

    /// `E_TYPE <site>: expected <expected>, got <actual>`.
    pub fn type_mismatch(site: &str, expected: &str, actual: &str) -> Error {
        Error::new(
            ErrorKind::Type,
            format!("{site}: expected {expected}, got {actual}"),
        )
    }

    /// `E_ARITY <kind> <name>: expected <expected>, got <got>`.
    pub fn arity(kind: &str, name: &str, expected: &str, got: usize) -> Error {
        Error::new(
            ErrorKind::Arity,
            format!("{kind} {name}: expected {expected}, got {got}"),
        )
    }

    /// `E_ARG <kind> <name>: <reason>`.
    pub fn arg(kind: &str, name: &str, reason: &str) -> Error {
        Error::new(ErrorKind::Arg, format!("{kind} {name}: {reason}"))
    }

    /// The error's kind.
    pub fn kind(&self) -> ErrorKind {
        self.kind
    }

    /// The error's detail bytes.
    pub fn detail(&self) -> &[u8] {
        &self.detail
    }

    /// Renders `KIND detail` exactly as it appears after `  error ` in the log.
    pub fn render(&self) -> Vec<u8> {
        let mut out = self.kind.code().as_bytes().to_vec();
        if self.kind.has_detail() {
            out.push(b' ');
            out.extend_from_slice(&self.detail);
        }
        out
    }
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&String::from_utf8_lossy(&self.render()))
    }
}

impl std::error::Error for Error {}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn render_with_and_without_detail() {
        assert_eq!(Error::bare(ErrorKind::NoDefault).to_string(), "E_NO_DEFAULT");
        assert_eq!(
            Error::new(ErrorKind::UnknownVar, "x").to_string(),
            "E_UNKNOWN_VAR x"
        );
        assert_eq!(
            Error::type_mismatch("operator +", "int", "str").to_string(),
            "E_TYPE operator +: expected int, got str"
        );
        assert_eq!(Error::parse("main.kiln", 3).to_string(), "E_PARSE main.kiln:3");
    }
}
