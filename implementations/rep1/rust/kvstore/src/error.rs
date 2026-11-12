//! Error kinds raised by the command language and the storage engine.

use std::fmt;

/// The reason a command failed.
///
/// The first eighteen variants are the error kinds of the specification (the
/// text after `error ` in a result block is [`Error::name`]). A failing
/// command never modifies the database.
///
/// [`Error::Corrupt`] is not part of the command language: it is returned
/// instead of panicking when stored bytes cannot be decoded, which cannot
/// happen for files produced by this crate.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Error {
    /// The line does not lex or does not parse.
    Syntax,
    /// The first token is a word that is not a command.
    UnknownCommand,
    /// A `\uXXXX` escape leaves an unpaired surrogate.
    BadUtf8,
    /// An integer literal does not fit in 64 bits.
    IntRange,
    /// An object literal names a field twice.
    DupField,
    /// A value nests deeper than [`crate::MAX_DEPTH`].
    Depth,
    /// A key is empty or longer than [`crate::MAX_KEY`] bytes.
    BadKey,
    /// A field path has too many segments or is too long.
    BadPath,
    /// The key is not in the store.
    NotFound,
    /// `unset` on a path that is missing from the document.
    NoField,
    /// A path traverses a value that is not an object.
    NotObject,
    /// The serialised document exceeds [`crate::MAX_DOC`] bytes.
    DocTooLarge,
    /// An index key would exceed [`crate::MAX_INDEX_KEY`] bytes.
    IndexKeyTooLong,
    /// `create index` on a path that already has an index.
    IndexExists,
    /// `drop index` on a path that has no index.
    IndexMissing,
    /// `create index` with all sixteen slots in use.
    IndexLimit,
    /// `begin` or `checkpoint` while a transaction is open.
    TxnActive,
    /// `commit` or `rollback` with no transaction open.
    NoTxn,
    /// Stored data could not be decoded (not a command-language error).
    Corrupt,
}

impl Error {
    /// The kind name used in `results.txt`, e.g. `"not-found"`.
    pub fn name(&self) -> &'static str {
        match self {
            Error::Syntax => "syntax",
            Error::UnknownCommand => "unknown-command",
            Error::BadUtf8 => "bad-utf8",
            Error::IntRange => "int-range",
            Error::DupField => "dup-field",
            Error::Depth => "depth",
            Error::BadKey => "bad-key",
            Error::BadPath => "bad-path",
            Error::NotFound => "not-found",
            Error::NoField => "no-field",
            Error::NotObject => "not-object",
            Error::DocTooLarge => "doc-too-large",
            Error::IndexKeyTooLong => "index-key-too-long",
            Error::IndexExists => "index-exists",
            Error::IndexMissing => "index-missing",
            Error::IndexLimit => "index-limit",
            Error::TxnActive => "txn-active",
            Error::NoTxn => "no-txn",
            Error::Corrupt => "corrupt",
        }
    }
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.name())
    }
}

impl std::error::Error for Error {}

/// Result alias used throughout the crate.
pub type Result<T> = std::result::Result<T, Error>;
