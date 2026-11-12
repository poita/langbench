//! # minisql
//!
//! A small in-memory relational database that executes a subset of SQL
//! (`CREATE TABLE`, `INSERT`, `UPDATE`, `DELETE`, and `SELECT` with up to
//! two tables, `WHERE`, `GROUP BY`, `HAVING`, `ORDER BY`, `LIMIT`/`OFFSET`
//! and the aggregates `COUNT`, `SUM`, `MIN`, `MAX`, `AVG`).
//!
//! Statements go through four stages, each in its own module:
//! [`lexer`] → [`parser`] (producing an [`ast`]) → [`binder`] (name
//! resolution and semantic checks) → [`exec`] (evaluation, using [`eval`]).
//! A statement that fails in any stage has no effect on the database.
//!
//! ```
//! use minisql::{Database, Output, Value};
//!
//! let mut db = Database::new();
//! db.execute("CREATE TABLE t (k INTEGER, v TEXT)").unwrap();
//! db.execute("INSERT INTO t VALUES (2, 'b'), (1, 'a')").unwrap();
//!
//! match db.execute("SELECT v FROM t ORDER BY k").unwrap() {
//!     Output::Rows(rs) => {
//!         assert_eq!(rs.rows, vec![vec![Value::text("a")], vec![Value::text("b")]]);
//!         assert_eq!(rs.to_string(), "a\nb\n-- 2 rows\n");
//!     }
//!     Output::None => unreachable!(),
//! }
//! assert!(db.execute("SELECT nope FROM t").is_err());
//! ```

pub mod ast;
pub mod binder;
pub mod db;
pub mod error;
pub mod eval;
pub mod exec;
pub mod lexer;
pub mod like;
pub mod parser;
pub mod result;
pub mod table;
pub mod value;

pub use db::Database;
pub use error::{Error, Result};
pub use result::{Output, ResultSet};
pub use value::Value;
