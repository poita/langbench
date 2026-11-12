//! Error codes and the one-line error report.

use std::fmt;

/// Every error code defined by the specification.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Code {
    MissingDocument,
    BadSyntax,
    UnknownSetting,
    DuplicateSetting,
    BadLength,
    BadInteger,
    BadBoolean,
    BadEnum,
    UnknownFont,
    UnknownPatterns,
    BadValue,
    BadEscape,
    UnknownPlaceholder,
    StrayBrace,
    UnknownBlock,
    BlockNotAllowed,
    DuplicateToc,
    UnexpectedEnd,
    MissingEnd,
    BadAttribute,
    MissingAttribute,
    BadAttributeValue,
    CellCount,
    TextNotAllowed,
    UnknownMeta,
    DuplicateMeta,
    UnknownInline,
    UnclosedInline,
    NestedFootnote,
    FootnoteNotAllowed,
}

impl Code {
    /// The code as written in `error.txt`.
    pub fn as_str(self) -> &'static str {
        use Code::*;
        match self {
            MissingDocument => "missing-document",
            BadSyntax => "bad-syntax",
            UnknownSetting => "unknown-setting",
            DuplicateSetting => "duplicate-setting",
            BadLength => "bad-length",
            BadInteger => "bad-integer",
            BadBoolean => "bad-boolean",
            BadEnum => "bad-enum",
            UnknownFont => "unknown-font",
            UnknownPatterns => "unknown-patterns",
            BadValue => "bad-value",
            BadEscape => "bad-escape",
            UnknownPlaceholder => "unknown-placeholder",
            StrayBrace => "stray-brace",
            UnknownBlock => "unknown-block",
            BlockNotAllowed => "block-not-allowed",
            DuplicateToc => "duplicate-toc",
            UnexpectedEnd => "unexpected-end",
            MissingEnd => "missing-end",
            BadAttribute => "bad-attribute",
            MissingAttribute => "missing-attribute",
            BadAttributeValue => "bad-attribute-value",
            CellCount => "cell-count",
            TextNotAllowed => "text-not-allowed",
            UnknownMeta => "unknown-meta",
            DuplicateMeta => "duplicate-meta",
            UnknownInline => "unknown-inline",
            UnclosedInline => "unclosed-inline",
            NestedFootnote => "nested-footnote",
            FootnoteNotAllowed => "footnote-not-allowed",
        }
    }
}

/// An invalid input, reported at a position in one of the input files.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Error {
    /// `settings.cfg`, `document.cdx` or `-`.
    pub file: &'static str,
    /// 1-based line (0 when there is no position).
    pub line: usize,
    /// 1-based column in Unicode scalar values.
    pub col: usize,
    pub code: Code,
}

pub const SETTINGS_FILE: &str = "settings.cfg";
pub const DOCUMENT_FILE: &str = "document.cdx";

impl Error {
    pub fn new(file: &'static str, line: usize, col: usize, code: Code) -> Error {
        Error { file, line, col, code }
    }

    /// An error in `settings.cfg`.
    pub fn settings(line: usize, col: usize, code: Code) -> Error {
        Error::new(SETTINGS_FILE, line, col, code)
    }

    /// An error in `document.cdx`.
    pub fn document(line: usize, col: usize, code: Code) -> Error {
        Error::new(DOCUMENT_FILE, line, col, code)
    }
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}:{}:{}: {}", self.file, self.line, self.col, self.code.as_str())
    }
}

impl std::error::Error for Error {}
