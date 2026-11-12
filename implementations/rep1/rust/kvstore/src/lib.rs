//! # Tessera
//!
//! An embedded, single-file transactional document store: a write-ahead log,
//! a B+tree primary index, overflow pages for large values, secondary indexes
//! on document fields, crash recovery, checkpointing, and a small command
//! language.
//!
//! The on-disk format is fully deterministic: the same sequence of commands
//! produces byte-identical `main.tdb` and `main.twal` images.
//!
//! The crate works on in-memory images of the two files; reading and writing
//! them is up to the caller (the `kvstore` binary does it for a directory).
//!
//! ```
//! use tessera::{Database, Value};
//!
//! let mut db = Database::new();
//! db.put(b"a", &Value::Int(1)).unwrap();
//! assert_eq!(db.get(b"a").unwrap(), Value::Int(1));
//!
//! // Or drive it with the command language and get `results.txt` text back.
//! let out = db.run_script("put \"b\" {name:\"ada\"}\nscan keys\n");
//! assert_eq!(out, "[1] ok put created\n[2] ok scan 2\n  \"a\"\n  \"b\"\n");
//!
//! // The two files, as they would be written to disk now.
//! let (main, log) = (db.main_bytes().to_vec(), db.wal_bytes().to_vec());
//! let reopened = Database::open(Some(&main), Some(&log)).unwrap();
//! assert_eq!(reopened.get(b"a").unwrap(), Value::Int(1));
//! ```
//!
//! ## Modules
//!
//! | Module | Responsibility |
//! |---|---|
//! | [`crc`] | CRC-32 |
//! | [`value`], [`path`] | document values and field paths |
//! | [`lexer`], [`parser`], [`command`], [`predicate`] | the command language |
//! | [`header`], [`pager`], [`wal`] | page storage, transactions, the log |
//! | [`btree`], [`overflow`], [`index`] | trees, overflow chains, index keys |
//! | [`db`], [`exec`], [`render`] | the engine, command execution, result text |

pub mod btree;
pub mod command;
pub mod crc;
pub mod db;
pub mod error;
pub mod exec;
pub mod header;
pub mod index;
pub mod lexer;
pub mod overflow;
pub mod pager;
pub mod parser;
pub mod path;
pub mod predicate;
pub mod render;
pub mod value;
pub mod wal;

pub use command::{Command, ScanOptions};
pub use db::{Database, FindResult, IndexInfo, PutOutcome, ScanRow, Stat};
pub use error::{Error, Result};
pub use exec::Response;
pub use parser::parse_command;
pub use path::Path;
pub use predicate::{CmpOp, Plan, Pred};
pub use value::Value;

/// Bytes per page.
pub const PAGE_SIZE: usize = 1024;
/// Maximum primary key length in bytes.
pub const MAX_KEY: usize = 128;
/// Maximum index key length in bytes.
pub const MAX_INDEX_KEY: usize = 128;
/// Document bytes held in a primary leaf cell.
pub const MAX_INLINE: usize = 192;
/// Document bytes held in one overflow page.
pub const OVF_PAYLOAD: usize = 1012;
/// Maximum serialised document length in bytes.
pub const MAX_DOC: usize = 65536;
/// Maximum value nesting depth.
pub const MAX_DEPTH: usize = 32;
/// Payload bytes available on a B+tree page.
pub const CAPACITY: usize = 1008;
/// Payload size below which a deletion triggers rebalancing.
pub const MIN_FILL: usize = 336;
/// Number of secondary-index directory slots.
pub const MAX_INDEXES: usize = 16;
/// Log size in bytes that triggers an automatic checkpoint.
pub const WAL_LIMIT: usize = 262_144;
/// Largest accepted `limit` argument.
pub const MAX_LIMIT: u32 = 2_147_483_647;

pub(crate) const MAGIC: &[u8; 8] = b"TESSERA1";
pub(crate) const WAL_MAGIC: &[u8; 8] = b"TESSWAL1";
