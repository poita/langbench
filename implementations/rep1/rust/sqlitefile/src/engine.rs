//! Query execution against an open database.

use crate::btree;
use crate::catalog::{Catalog, ColumnRef, Table};
use crate::error::{Error, Result};
use crate::pager::Database;
use crate::query::{self, Columns, Condition, Op, Query, Select};
use crate::record::Record;
use crate::value::{Affinity, Value};
use std::cmp::Ordering;
use std::path::Path;

/// A database together with its schema catalog, ready to answer queries.
///
/// The catalog is read once when the engine is created; nothing else is
/// cached between queries.
#[derive(Debug)]
pub struct Engine {
    db: Database,
    catalog: Catalog,
}

/// A `WHERE` condition resolved against a table.
struct BoundCondition {
    column: ColumnRef,
    op: Op,
    literal: Value,
}

impl Engine {
    /// Open the database file at `path` and read its schema.
    pub fn open(path: impl AsRef<Path>) -> Result<Engine> {
        Engine::from_database(Database::open(path)?)
    }

    /// Build an engine from the raw bytes of a database file.
    pub fn from_bytes(bytes: Vec<u8>) -> Result<Engine> {
        Engine::from_database(Database::from_bytes(bytes)?)
    }

    fn from_database(db: Database) -> Result<Engine> {
        let catalog = Catalog::load(&db)?;
        Ok(Engine { db, catalog })
    }

    /// The schema catalog.
    pub fn catalog(&self) -> &Catalog {
        &self.catalog
    }

    /// Run one query line and return its output: every line `\n`-terminated,
    /// empty if there are no rows.
    pub fn execute(&self, line: &str) -> Result<String> {
        match query::parse(line)? {
            Query::Tables => Ok(self.tables()),
            Query::Schema(name) => Ok(self.schema(&name)),
            Query::Count(name) => self.count(&name),
            Query::Select(sel) => self.select(&sel),
            Query::Index { name, literal } => self.index(&name, literal),
        }
    }

    /// Like [`Engine::execute`], but a failing query yields `"error\n"`.
    pub fn execute_or_error(&self, line: &str) -> String {
        self.execute(line).unwrap_or_else(|_| "error\n".to_string())
    }

    fn tables(&self) -> String {
        let mut names: Vec<&str> = self
            .catalog
            .rows()
            .iter()
            .filter(|r| r.kind == "table" && !r.name.to_ascii_lowercase().starts_with("sqlite_"))
            .map(|r| r.name.as_str())
            .collect();
        names.sort_by(|a, b| a.as_bytes().cmp(b.as_bytes()));
        names.iter().map(|n| format!("{n}\n")).collect()
    }

    fn schema(&self, table: &str) -> String {
        let mut out = String::new();
        for row in self.catalog.rows() {
            if row.tbl_name.eq_ignore_ascii_case(table) {
                if let Some(sql) = &row.sql {
                    out.push_str(sql);
                    out.push_str(";\n");
                }
            }
        }
        out
    }

    fn table(&self, name: &str) -> Result<&Table> {
        self.catalog
            .table(name)
            .ok_or_else(|| Error::semantic(format!("no such table: {name}")))
    }

    fn count(&self, name: &str) -> Result<String> {
        let t = self.table(name)?;
        Ok(format!("{}\n", btree::table_count(&self.db, t.rootpage)?))
    }

    fn select(&self, sel: &Select) -> Result<String> {
        let table = self.table(&sel.table)?;
        let projection: Vec<ColumnRef> = match &sel.columns {
            Columns::All => (0..table.columns.len()).map(ColumnRef::Column).collect(),
            Columns::Named(names) => names
                .iter()
                .map(|n| resolve(table, n))
                .collect::<Result<_>>()?,
        };
        let conditions = sel
            .conditions
            .iter()
            .map(|c| bind(table, c))
            .collect::<Result<Vec<_>>>()?;
        let order = match &sel.order_by {
            Some((name, desc)) => Some((resolve(table, name)?, *desc)),
            None => None,
        };

        if sel.limit == Some(0) {
            return Ok(String::new());
        }
        let limit = sel.limit.unwrap_or(u64::MAX);

        // (sort key, rowid, output line); the key is Null without ORDER BY.
        let mut matched: Vec<(Value, i64, String)> = Vec::new();
        btree::table_scan(&self.db, table.rootpage, |rowid, payload| {
            let rec = Record::parse(payload)?;
            for c in &conditions {
                let v = column_value(table, &rec, rowid, c.column)?;
                if !holds(&v, c.op, &c.literal) {
                    return Ok(true);
                }
            }
            let key = match order {
                Some((col, _)) => column_value(table, &rec, rowid, col)?,
                None => Value::Null,
            };
            matched.push((key, rowid, format_row(table, &rec, rowid, &projection)?));
            Ok(order.is_some() || (matched.len() as u64) < limit)
        })?;

        if let Some((_, desc)) = order {
            matched.sort_by(|a, b| {
                let o = a.0.compare(&b.0);
                let o = if desc { o.reverse() } else { o };
                o.then(a.1.cmp(&b.1))
            });
        }
        let take = usize::try_from(limit).unwrap_or(usize::MAX);
        let mut out = String::new();
        for (_, _, line) in matched.into_iter().take(take) {
            out.push_str(&line);
            out.push('\n');
        }
        Ok(out)
    }

    fn index(&self, name: &str, literal: Value) -> Result<String> {
        let index = self
            .catalog
            .index(name)
            .ok_or_else(|| Error::semantic(format!("no such index: {name}")))?;
        if index.columns.len() != 1 {
            return Err(Error::semantic("index must have exactly one column"));
        }
        let table = self.table(&index.table)?;
        let column = resolve(table, &index.columns[0])?;
        let key = table.affinity(column).apply_to_literal(literal);
        if key.is_null() {
            return Ok(String::new());
        }
        let mut rowids = btree::index_lookup(&self.db, index.rootpage, &key)?;
        rowids.sort_unstable();
        rowids.dedup();
        let projection: Vec<ColumnRef> = (0..table.columns.len()).map(ColumnRef::Column).collect();
        let mut out = String::new();
        for rowid in rowids {
            if let Some(payload) = btree::table_find(&self.db, table.rootpage, rowid)? {
                let rec = Record::parse(&payload)?;
                out.push_str(&format_row(table, &rec, rowid, &projection)?);
                out.push('\n');
            }
        }
        Ok(out)
    }
}

fn resolve(table: &Table, name: &str) -> Result<ColumnRef> {
    table
        .resolve(name)
        .ok_or_else(|| Error::semantic(format!("no such column: {name}")))
}

fn bind(table: &Table, c: &Condition) -> Result<BoundCondition> {
    let column = resolve(table, &c.column)?;
    Ok(BoundCondition {
        column,
        op: c.op,
        literal: table.affinity(column).apply_to_literal(c.literal.clone()),
    })
}

/// The value of a column in a row, applying the rowid alias and the REAL
/// widening rule (SPEC §§2.2, 2.4).
fn column_value(table: &Table, rec: &Record<'_>, rowid: i64, c: ColumnRef) -> Result<Value> {
    match c {
        ColumnRef::Rowid => Ok(Value::Integer(rowid)),
        ColumnRef::Column(i) if table.rowid_alias == Some(i) => Ok(Value::Integer(rowid)),
        ColumnRef::Column(i) => {
            let v = rec.get(i)?;
            Ok(match (v, table.columns[i].affinity) {
                (Value::Integer(n), Affinity::Real) => Value::Real(n as f64),
                (v, _) => v,
            })
        }
    }
}

fn format_row(table: &Table, rec: &Record<'_>, rowid: i64, cols: &[ColumnRef]) -> Result<String> {
    let mut line = String::new();
    for (n, &c) in cols.iter().enumerate() {
        if n > 0 {
            line.push('\t');
        }
        line.push_str(&column_value(table, rec, rowid, c)?.to_string());
    }
    Ok(line)
}

/// Evaluate `value <op> literal` (SPEC §4.4).
fn holds(value: &Value, op: Op, literal: &Value) -> bool {
    match op {
        Op::Is => value.compare(literal) == Ordering::Equal,
        Op::IsNot => value.compare(literal) != Ordering::Equal,
        _ if value.is_null() || literal.is_null() => false,
        _ => {
            let o = value.compare(literal);
            match op {
                Op::Eq => o == Ordering::Equal,
                Op::Ne => o != Ordering::Equal,
                Op::Lt => o == Ordering::Less,
                Op::Le => o != Ordering::Greater,
                Op::Gt => o == Ordering::Greater,
                Op::Ge => o != Ordering::Less,
                Op::Is | Op::IsNot => unreachable!(),
            }
        }
    }
}
