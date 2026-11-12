//! The schema catalog, read once from `sqlite_schema` (SPEC §1.10, Part 2).

use crate::btree;
use crate::ddl::{self, IndexDef, TableDef};
use crate::error::{Error, Result};
use crate::pager::Database;
use crate::record::Record;
use crate::value::{Affinity, Value};
use std::collections::HashMap;

/// One row of `sqlite_schema`.
#[derive(Debug, Clone)]
pub struct SchemaRow {
    /// `table`, `index`, `view` or `trigger`.
    pub kind: String,
    /// The object's name.
    pub name: String,
    /// The table the object belongs to.
    pub tbl_name: String,
    /// Root page, 0 when the object has no B-tree.
    pub rootpage: u32,
    /// The `CREATE` statement, if any.
    pub sql: Option<String>,
}

/// A table column with its derived affinity.
#[derive(Debug, Clone)]
pub struct Column {
    /// Column name.
    pub name: String,
    /// Affinity derived from the declared type.
    pub affinity: Affinity,
}

/// A table known to the catalog.
#[derive(Debug, Clone)]
pub struct Table {
    /// Table name.
    pub name: String,
    /// Root page of the table B-tree.
    pub rootpage: u32,
    /// Columns in declaration order.
    pub columns: Vec<Column>,
    /// Index of the column aliasing the rowid, if any.
    pub rowid_alias: Option<usize>,
}

/// An index created by an explicit `CREATE INDEX` statement.
#[derive(Debug, Clone)]
pub struct Index {
    /// Index name.
    pub name: String,
    /// Name of the indexed table.
    pub table: String,
    /// Root page of the index B-tree.
    pub rootpage: u32,
    /// Indexed column names.
    pub columns: Vec<String>,
}

/// Which column a name refers to.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ColumnRef {
    /// The column at this position in the declared order.
    Column(usize),
    /// The row's rowid.
    Rowid,
}

impl Table {
    /// Resolve a column name case-insensitively; the pseudo-column `rowid`
    /// resolves only if no real column has that name.
    pub fn resolve(&self, name: &str) -> Option<ColumnRef> {
        if let Some(i) = self
            .columns
            .iter()
            .position(|c| c.name.eq_ignore_ascii_case(name))
        {
            return Some(ColumnRef::Column(i));
        }
        name.eq_ignore_ascii_case("rowid").then_some(ColumnRef::Rowid)
    }

    /// Affinity of a resolved column (the rowid has INTEGER affinity).
    pub fn affinity(&self, c: ColumnRef) -> Affinity {
        match c {
            ColumnRef::Column(i) => self.columns[i].affinity,
            ColumnRef::Rowid => Affinity::Integer,
        }
    }
}

/// Everything learned from `sqlite_schema`.
#[derive(Debug, Default)]
pub struct Catalog {
    rows: Vec<SchemaRow>,
    tables: Vec<Table>,
    table_ix: HashMap<String, usize>,
    indexes: Vec<Index>,
    index_ix: HashMap<String, usize>,
}

impl Catalog {
    /// Read and parse `sqlite_schema` (the table rooted at page 1).
    pub fn load(db: &Database) -> Result<Catalog> {
        let mut rows = Vec::new();
        btree::table_scan(db, 1, |_, payload| {
            let rec = Record::parse(payload)?;
            let text = |i| -> Result<String> {
                Ok(match rec.get(i)? {
                    Value::Text(s) => s,
                    _ => String::new(),
                })
            };
            let rootpage = match rec.get(3)? {
                Value::Integer(n) => u32::try_from(n).unwrap_or(0),
                _ => 0,
            };
            let sql = match rec.get(4)? {
                Value::Text(s) => Some(s),
                _ => None,
            };
            rows.push(SchemaRow {
                kind: text(0)?,
                name: text(1)?,
                tbl_name: text(2)?,
                rootpage,
                sql,
            });
            Ok(true)
        })
        .map_err(|e| match e {
            Error::Corrupt(m) => Error::Corrupt(format!("sqlite_schema: {m}")),
            e => e,
        })?;

        let mut cat = Catalog { rows, ..Catalog::default() };
        for row in &cat.rows {
            let Some(sql) = &row.sql else { continue };
            match row.kind.as_str() {
                "table" => {
                    if let Ok(def) = ddl::parse_create_table(sql) {
                        let t = table_from_def(row, def);
                        let key = row.name.to_ascii_lowercase();
                        if !cat.table_ix.contains_key(&key) {
                            cat.table_ix.insert(key, cat.tables.len());
                            cat.tables.push(t);
                        }
                    }
                }
                "index" => {
                    if let Ok(def) = ddl::parse_create_index(sql) {
                        let ix = index_from_def(row, def);
                        let key = row.name.to_ascii_lowercase();
                        if !cat.index_ix.contains_key(&key) {
                            cat.index_ix.insert(key, cat.indexes.len());
                            cat.indexes.push(ix);
                        }
                    }
                }
                _ => {}
            }
        }
        Ok(cat)
    }

    /// All `sqlite_schema` rows in schema (rowid) order.
    pub fn rows(&self) -> &[SchemaRow] {
        &self.rows
    }

    /// Look up a table by name, ASCII case-insensitively.
    pub fn table(&self, name: &str) -> Option<&Table> {
        self.table_ix
            .get(&name.to_ascii_lowercase())
            .map(|&i| &self.tables[i])
    }

    /// Look up an explicitly created index by name, ASCII case-insensitively.
    pub fn index(&self, name: &str) -> Option<&Index> {
        self.index_ix
            .get(&name.to_ascii_lowercase())
            .map(|&i| &self.indexes[i])
    }
}

fn table_from_def(row: &SchemaRow, def: TableDef) -> Table {
    Table {
        name: row.name.clone(),
        rootpage: row.rootpage,
        columns: def
            .columns
            .into_iter()
            .enumerate()
            .map(|(i, c)| Column {
                name: c.name,
                affinity: if def.rowid_alias == Some(i) {
                    Affinity::Integer
                } else {
                    Affinity::from_declared_type(&c.declared_type)
                },
            })
            .collect(),
        rowid_alias: def.rowid_alias,
    }
}

fn index_from_def(row: &SchemaRow, def: IndexDef) -> Index {
    Index {
        name: row.name.clone(),
        table: row.tbl_name.clone(),
        rootpage: row.rootpage,
        columns: def.columns,
    }
}
