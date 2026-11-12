//! Query results and their textual rendering.

use std::fmt;

use crate::value::Value;

/// The rows produced by a `SELECT`.
#[derive(Debug, Clone, PartialEq)]
pub struct ResultSet {
    /// Output rows in result order.
    pub rows: Vec<Vec<Value>>,
}

impl fmt::Display for ResultSet {
    /// One tab-separated line per row, followed by `-- N rows`.
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        for row in &self.rows {
            for (i, v) in row.iter().enumerate() {
                if i > 0 {
                    f.write_str("\t")?;
                }
                write!(f, "{v}")?;
            }
            f.write_str("\n")?;
        }
        writeln!(f, "-- {} rows", self.rows.len())
    }
}

/// What a successfully executed statement produced.
#[derive(Debug, Clone, PartialEq)]
pub enum Output {
    /// `CREATE`, `INSERT`, `UPDATE` or `DELETE`: nothing to print.
    None,
    /// A `SELECT`'s rows.
    Rows(ResultSet),
}
