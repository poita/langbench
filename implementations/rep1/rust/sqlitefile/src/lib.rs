//! # sqlitefile
//!
//! A from-scratch reader for SQLite 3 database files. It parses the file
//! format directly (pages, B-trees, records, overflow chains), reads the
//! schema, and answers a small query language:
//!
//! | query                          | meaning                                  |
//! |--------------------------------|------------------------------------------|
//! | `.tables`                      | user table names, sorted                 |
//! | `.schema <table>`              | `CREATE` statements for a table          |
//! | `COUNT <table>`                | number of rows                           |
//! | `SELECT cols FROM t [WHERE ..] [ORDER BY c [ASC\|DESC]] [LIMIT n]` | rows |
//! | `INDEX <index> <literal>`      | point lookup through an index B-tree     |
//!
//! ```no_run
//! use sqlitefile::Engine;
//!
//! # fn main() -> Result<(), sqlitefile::Error> {
//! let engine = Engine::open("people.sqlite")?;
//! print!("{}", engine.execute("SELECT name FROM people WHERE age > 40")?);
//! // Failing queries can be rendered the way the CLI does:
//! assert_eq!(engine.execute_or_error("SELECT nope FROM people"), "error\n");
//! # Ok(()) }
//! ```
//!
//! # Modules
//!
//! * [`pager`] — the database file in memory and page access;
//! * [`btree`] — table scans, counts, rowid seeks and index lookups;
//! * [`record`] — record (row) decoding;
//! * [`varint`] — SQLite varints;
//! * [`ddl`] — `CREATE TABLE` / `CREATE INDEX` parsing;
//! * [`catalog`] — the schema catalog;
//! * [`value`] — values, affinity, ordering and formatting;
//! * [`query`] — the query-language parser;
//! * [`engine`] — query execution.

pub mod btree;
pub mod catalog;
pub mod ddl;
pub mod engine;
pub mod error;
pub mod pager;
pub mod query;
pub mod record;
pub mod value;
pub mod varint;

pub use engine::Engine;
pub use error::{Error, Result};
pub use value::Value;
