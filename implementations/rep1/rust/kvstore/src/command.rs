//! The parsed form of a command line.

use crate::path::Path;
use crate::predicate::Pred;
use crate::value::Value;

/// Options of a `scan`.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ScanOptions {
    /// Inclusive lower bound (any byte string).
    pub from: Option<Vec<u8>>,
    /// Exclusive upper bound (any byte string).
    pub to: Option<Vec<u8>>,
    /// Maximum number of results, applied after ordering.
    pub limit: Option<u32>,
    /// Emit in descending key order.
    pub reverse: bool,
    /// Emit keys only.
    pub keys_only: bool,
}

/// One command of the command language.
#[derive(Clone, Debug, PartialEq)]
pub enum Command {
    /// `begin`
    Begin,
    /// `commit`
    Commit,
    /// `rollback`
    Rollback,
    /// `checkpoint`
    Checkpoint,
    /// `stat`
    Stat,
    /// `indexes`
    Indexes,
    /// `put <key> <value>`
    Put {
        /// Document key.
        key: Vec<u8>,
        /// Document.
        value: Value,
    },
    /// `get <key>`
    Get {
        /// Document key.
        key: Vec<u8>,
    },
    /// `delete <key>`
    Delete {
        /// Document key.
        key: Vec<u8>,
    },
    /// `update <key> <path> <value>`
    Update {
        /// Document key.
        key: Vec<u8>,
        /// Field to set.
        path: Path,
        /// New field value.
        value: Value,
    },
    /// `unset <key> <path>`
    Unset {
        /// Document key.
        key: Vec<u8>,
        /// Field to remove.
        path: Path,
    },
    /// `scan [from K] [to K] [limit N] [reverse] [keys]`
    Scan(ScanOptions),
    /// `find <predicate> [limit N]`
    Find {
        /// The predicate.
        pred: Pred,
        /// Maximum number of results.
        limit: Option<u32>,
    },
    /// `create index <path>`
    CreateIndex(Path),
    /// `drop index <path>`
    DropIndex(Path),
}
