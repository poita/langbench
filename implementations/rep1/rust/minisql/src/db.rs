//! The [`Database`]: a catalog of tables and the statement entry points.

use std::collections::HashMap;
use std::io::{self, Write};

use crate::ast::{ColumnType, Expr, Statement};
use crate::binder::{bind_expr, bind_select, AggMode, Scope};
use crate::error::{Error, Result};
use crate::eval::{eval, Env};
use crate::exec::{exec_delete, exec_select, exec_update};
use crate::lexer::{split_statements, tokenize};
use crate::parser::parse_statement;
use crate::result::Output;
use crate::table::{Column, Table};

/// An in-memory database.
#[derive(Debug, Default, Clone)]
pub struct Database {
    tables: HashMap<String, Table>,
}

impl Database {
    /// Creates an empty database.
    pub fn new() -> Database {
        Database::default()
    }

    /// Looks up a table by (case-insensitive) name.
    pub fn table(&self, name: &str) -> Option<&Table> {
        self.tables.get(&name.to_ascii_lowercase())
    }

    /// Executes exactly one statement (a trailing `;` is optional).
    ///
    /// # Errors
    /// Any syntax or semantic error; the database is left unchanged.
    pub fn execute(&mut self, sql: &str) -> Result<Output> {
        let tokens = tokenize(sql);
        let stmts = split_statements(&tokens);
        match stmts.as_slice() {
            [one] => self.run_statement(parse_statement(one)?),
            _ => Err(Error::syntax("expected exactly one statement")),
        }
    }

    /// Executes a script, calling `sink` with the outcome of each
    /// statement as it completes. Execution continues after errors.
    pub fn run_script_with(&mut self, script: &str, mut sink: impl FnMut(Result<Output>)) {
        let tokens = tokenize(script);
        for stmt in split_statements(&tokens) {
            let outcome = parse_statement(stmt).and_then(|s| self.run_statement(s));
            sink(outcome);
        }
    }

    /// Executes a script and collects one outcome per non-empty statement.
    pub fn run_script(&mut self, script: &str) -> Vec<Result<Output>> {
        let mut all = Vec::new();
        self.run_script_with(script, |o| all.push(o));
        all
    }

    /// Executes a script and writes the command-line tool's output format:
    /// each `SELECT`'s rows followed by `-- N rows`, and a line `error`
    /// for each failing statement.
    ///
    /// # Errors
    /// Only I/O errors from `out`.
    pub fn run_script_to<W: Write>(&mut self, script: &str, out: &mut W) -> io::Result<()> {
        let mut status = Ok(());
        self.run_script_with(script, |o| {
            if status.is_err() {
                return;
            }
            status = match o {
                Ok(Output::None) => Ok(()),
                Ok(Output::Rows(rs)) => write!(out, "{rs}"),
                Err(_) => writeln!(out, "error"),
            };
        });
        status
    }

    fn run_statement(&mut self, stmt: Statement) -> Result<Output> {
        match stmt {
            Statement::CreateTable { name, columns } => self.create_table(name, columns),
            Statement::Insert { table, rows } => self.insert(&table, &rows),
            Statement::Delete { table, filter } => {
                let t = self.tables.get(&table).ok_or_else(|| no_table(&table))?;
                let scope = Scope::single(t);
                let filter = filter
                    .as_ref()
                    .map(|f| bind_expr(&scope, f, AggMode::Forbidden))
                    .transpose()?;
                exec_delete(self.tables.get_mut(&table).unwrap(), filter.as_ref());
                Ok(Output::None)
            }
            Statement::Update { table, assignments, filter } => {
                let t = self.tables.get(&table).ok_or_else(|| no_table(&table))?;
                let scope = Scope::single(t);
                let mut bound = Vec::new();
                for (col, expr) in &assignments {
                    let idx = t
                        .column_index(col)
                        .ok_or_else(|| Error::semantic(format!("no such column: {col}")))?;
                    bound.push((idx, bind_expr(&scope, expr, AggMode::Forbidden)?));
                }
                let filter = filter
                    .as_ref()
                    .map(|f| bind_expr(&scope, f, AggMode::Forbidden))
                    .transpose()?;
                exec_update(self.tables.get_mut(&table).unwrap(), &bound, filter.as_ref());
                Ok(Output::None)
            }
            Statement::Select(sel) => {
                let bound = bind_select(&self.tables, &sel)?;
                Ok(Output::Rows(exec_select(&self.tables, &bound)))
            }
        }
    }

    fn create_table(&mut self, name: String, columns: Vec<(String, ColumnType)>) -> Result<Output> {
        if self.tables.contains_key(&name) {
            return Err(Error::semantic(format!("table {name} already exists")));
        }
        if columns.is_empty() {
            return Err(Error::semantic("no columns"));
        }
        for (i, (c, _)) in columns.iter().enumerate() {
            if columns[..i].iter().any(|(d, _)| d == c) {
                return Err(Error::semantic(format!("duplicate column {c}")));
            }
        }
        let columns = columns.into_iter().map(|(name, ty)| Column { name, ty }).collect();
        self.tables.insert(name.clone(), Table { name, columns, rows: Vec::new() });
        Ok(Output::None)
    }

    fn insert(&mut self, table: &str, rows: &[Vec<Expr>]) -> Result<Output> {
        let t = self.tables.get(table).ok_or_else(|| no_table(table))?;
        let scope = Scope::empty();
        let env = Env { left: &[], right: &[], nleft: 0 };
        let mut new_rows = Vec::with_capacity(rows.len());
        for row in rows {
            if row.len() != t.columns.len() {
                return Err(Error::semantic("wrong number of values"));
            }
            let mut vals = Vec::with_capacity(row.len());
            for e in row {
                let b = bind_expr(&scope, e, AggMode::Forbidden)?;
                vals.push(eval(&b, &env, None));
            }
            new_rows.push(vals);
        }
        self.tables.get_mut(table).unwrap().rows.extend(new_rows);
        Ok(Output::None)
    }
}

fn no_table(name: &str) -> Error {
    Error::semantic(format!("no such table: {name}"))
}
