//! Stored tables.

use crate::ast::ColumnType;
use crate::value::Value;

/// One stored row.
pub type Row = Vec<Value>;

/// A column definition.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Column {
    /// Lower-case column name.
    pub name: String,
    /// Declared type (informational only; values are never converted).
    pub ty: ColumnType,
}

/// A table: named columns plus rows in insertion order.
#[derive(Debug, Clone, PartialEq)]
pub struct Table {
    /// Lower-case table name.
    pub name: String,
    /// Column definitions in declaration order.
    pub columns: Vec<Column>,
    /// Rows in insertion order.
    pub rows: Vec<Row>,
}

impl Table {
    /// Index of the column called `name` (already lower-case).
    pub fn column_index(&self, name: &str) -> Option<usize> {
        self.columns.iter().position(|c| c.name == name)
    }
}
