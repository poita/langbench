//! Name resolution and semantic checks.
//!
//! The binder turns the [`ast`](crate::ast) into a *bound* tree in which
//! every column reference is a position in the (possibly joined) row, and
//! verifies everything that can be checked without data. Execution never
//! starts for a statement that fails here, so failing statements have no
//! effect.

use std::collections::HashMap;

use crate::ast::{self, AggFunc, BinOp, ColumnRef, Expr, SelectItem};
use crate::error::{Error, Result};
use crate::table::Table;
use crate::value::Value;

/// A bound expression.
#[derive(Debug, Clone)]
pub enum BExpr {
    /// A literal.
    Const(Value),
    /// Position in the concatenation of the FROM tables' columns.
    Col(usize),
    /// Unary minus.
    Neg(Box<BExpr>),
    /// `NOT`.
    Not(Box<BExpr>),
    /// Binary operator.
    Binary(BinOp, Box<BExpr>, Box<BExpr>),
    /// `IS NULL` (`false`) / `IS NOT NULL` (`true`).
    IsNull(Box<BExpr>, bool),
    /// `LIKE` (`false`) / `NOT LIKE` (`true`).
    Like(Box<BExpr>, Box<BExpr>, bool),
    /// Aggregate call; `None` argument is `COUNT(*)`.
    Agg(AggFunc, Option<Box<BExpr>>),
}

impl BExpr {
    /// Whether an aggregate call occurs anywhere in the expression.
    pub fn contains_agg(&self) -> bool {
        match self {
            BExpr::Const(_) | BExpr::Col(_) => false,
            BExpr::Neg(e) | BExpr::Not(e) | BExpr::IsNull(e, _) => e.contains_agg(),
            BExpr::Binary(_, a, b) | BExpr::Like(a, b, _) => a.contains_agg() || b.contains_agg(),
            BExpr::Agg(..) => true,
        }
    }

    /// Which FROM tables the expression reads: bit 0 = first (columns
    /// below `nleft`), bit 1 = second.
    pub fn table_mask(&self, nleft: usize) -> u8 {
        match self {
            BExpr::Const(_) => 0,
            BExpr::Col(i) => {
                if *i < nleft {
                    1
                } else {
                    2
                }
            }
            BExpr::Neg(e) | BExpr::Not(e) | BExpr::IsNull(e, _) => e.table_mask(nleft),
            BExpr::Binary(_, a, b) | BExpr::Like(a, b, _) => {
                a.table_mask(nleft) | b.table_mask(nleft)
            }
            BExpr::Agg(_, a) => a.as_ref().map_or(0, |e| e.table_mask(nleft)),
        }
    }
}

/// Where an ORDER BY term takes its key from.
#[derive(Debug, Clone)]
pub enum OrderKey {
    /// The value of the n-th output column (alias or ordinal reference).
    Output(usize),
    /// An expression evaluated against the row or group.
    Expr(BExpr),
}

/// A bound ORDER BY term.
#[derive(Debug, Clone)]
pub struct BoundOrder {
    /// Sort key.
    pub key: OrderKey,
    /// Descending order.
    pub desc: bool,
}

/// A fully bound `SELECT`.
#[derive(Debug, Clone)]
pub struct BoundSelect {
    /// Name of the first FROM table (`None` for a SELECT without FROM).
    pub left: Option<String>,
    /// Name of the second FROM table.
    pub right: Option<String>,
    /// Number of columns of the first table.
    pub nleft: usize,
    /// WHERE and ON expressions split at top-level `AND`s.
    pub conjuncts: Vec<BExpr>,
    /// Output expressions (`*` already expanded).
    pub items: Vec<BExpr>,
    /// Positions of the GROUP BY columns.
    pub group_cols: Vec<usize>,
    /// Whether this is an aggregate query.
    pub aggregate: bool,
    /// HAVING expression.
    pub having: Option<BExpr>,
    /// ORDER BY terms.
    pub order: Vec<BoundOrder>,
    /// LIMIT.
    pub limit: Option<usize>,
    /// OFFSET.
    pub offset: usize,
}

struct ScopeTable<'a> {
    /// Effective name: the alias if present, else the table name.
    name: String,
    table: &'a Table,
    offset: usize,
}

/// The tables visible to column references.
pub struct Scope<'a> {
    tables: Vec<ScopeTable<'a>>,
}

impl<'a> Scope<'a> {
    /// A scope with no tables.
    pub fn empty() -> Scope<'static> {
        Scope { tables: Vec::new() }
    }

    /// A scope over one table under its own name.
    pub fn single(table: &'a Table) -> Scope<'a> {
        Scope { tables: vec![ScopeTable { name: table.name.clone(), table, offset: 0 }] }
    }

    fn total_columns(&self) -> usize {
        self.tables.iter().map(|t| t.table.columns.len()).sum()
    }

    /// Resolves a column reference to its position.
    pub fn resolve(&self, col: &ColumnRef) -> Result<usize> {
        match &col.qualifier {
            Some(q) => {
                let t = self
                    .tables
                    .iter()
                    .find(|t| &t.name == q)
                    .ok_or_else(|| Error::semantic(format!("no such table: {q}")))?;
                t.table
                    .column_index(&col.name)
                    .map(|i| t.offset + i)
                    .ok_or_else(|| Error::semantic(format!("no such column: {q}.{}", col.name)))
            }
            None => {
                let mut found = None;
                for t in &self.tables {
                    if let Some(i) = t.table.column_index(&col.name) {
                        if found.is_some() {
                            return Err(Error::semantic(format!("ambiguous column: {}", col.name)));
                        }
                        found = Some(t.offset + i);
                    }
                }
                found.ok_or_else(|| Error::semantic(format!("no such column: {}", col.name)))
            }
        }
    }
}

/// Whether aggregate calls are permitted at the current position.
#[derive(Clone, Copy, PartialEq, Eq)]
pub enum AggMode {
    /// Not allowed (WHERE, ON, INSERT, UPDATE, DELETE).
    Forbidden,
    /// Allowed (select list, HAVING, ORDER BY).
    Allowed,
    /// Inside an aggregate's argument: nesting is an error.
    Inside,
}

/// Binds an expression against `scope`.
pub fn bind_expr(scope: &Scope<'_>, e: &Expr, mode: AggMode) -> Result<BExpr> {
    let b = |e: &Expr| bind_expr(scope, e, mode).map(Box::new);
    Ok(match e {
        Expr::Int(i) => BExpr::Const(Value::Int(*i)),
        Expr::Str(s) => BExpr::Const(Value::text(s)),
        Expr::Null => BExpr::Const(Value::Null),
        Expr::Column(c) => BExpr::Col(scope.resolve(c)?),
        Expr::Neg(x) => BExpr::Neg(b(x)?),
        Expr::Not(x) => BExpr::Not(b(x)?),
        Expr::Binary { op, lhs, rhs } => BExpr::Binary(*op, b(lhs)?, b(rhs)?),
        Expr::IsNull { expr, negated } => BExpr::IsNull(b(expr)?, *negated),
        Expr::Like { expr, pattern, negated } => BExpr::Like(b(expr)?, b(pattern)?, *negated),
        Expr::Aggregate { func, arg } => match mode {
            AggMode::Forbidden => return Err(Error::semantic("aggregate not allowed here")),
            AggMode::Inside => return Err(Error::semantic("nested aggregate")),
            AggMode::Allowed => {
                let arg = match arg {
                    Some(a) => Some(Box::new(bind_expr(scope, a, AggMode::Inside)?)),
                    None => None,
                };
                BExpr::Agg(*func, arg)
            }
        },
    })
}

/// Splits a bound expression at top-level `AND`s.
pub fn split_conjuncts(e: BExpr, out: &mut Vec<BExpr>) {
    match e {
        BExpr::Binary(BinOp::And, a, b) => {
            split_conjuncts(*a, out);
            split_conjuncts(*b, out);
        }
        other => out.push(other),
    }
}

/// In an aggregate query, columns outside aggregate calls must be grouped.
fn check_grouped(e: &BExpr, group_cols: &[usize]) -> Result<()> {
    match e {
        BExpr::Const(_) | BExpr::Agg(..) => Ok(()),
        BExpr::Col(i) => {
            if group_cols.contains(i) {
                Ok(())
            } else {
                Err(Error::semantic("column must appear in GROUP BY or an aggregate"))
            }
        }
        BExpr::Neg(x) | BExpr::Not(x) | BExpr::IsNull(x, _) => check_grouped(x, group_cols),
        BExpr::Binary(_, a, b) | BExpr::Like(a, b, _) => {
            check_grouped(a, group_cols)?;
            check_grouped(b, group_cols)
        }
    }
}

fn lookup<'a>(tables: &'a HashMap<String, Table>, name: &str) -> Result<&'a Table> {
    tables.get(name).ok_or_else(|| Error::semantic(format!("no such table: {name}")))
}

/// Binds a `SELECT` against the current set of tables.
pub fn bind_select(tables: &HashMap<String, Table>, sel: &ast::Select) -> Result<BoundSelect> {
    // FROM
    let mut scope = Scope::empty();
    let (mut left, mut right, mut nleft) = (None, None, 0);
    if let Some(from) = &sel.from {
        let t1 = lookup(tables, &from.first.name)?;
        nleft = t1.columns.len();
        left = Some(t1.name.clone());
        scope.tables.push(ScopeTable {
            name: from.first.alias.clone().unwrap_or_else(|| t1.name.clone()),
            table: t1,
            offset: 0,
        });
        if let Some(second) = &from.second {
            let t2 = lookup(tables, &second.name)?;
            let name = second.alias.clone().unwrap_or_else(|| t2.name.clone());
            if name == scope.tables[0].name {
                return Err(Error::semantic("duplicate table name in FROM"));
            }
            right = Some(t2.name.clone());
            scope.tables.push(ScopeTable { name, table: t2, offset: nleft });
        }
    }

    // WHERE / ON
    let mut conjuncts = Vec::new();
    if let Some(on) = sel.from.as_ref().and_then(|f| f.on.as_ref()) {
        split_conjuncts(bind_expr(&scope, on, AggMode::Forbidden)?, &mut conjuncts);
    }
    if let Some(w) = &sel.filter {
        split_conjuncts(bind_expr(&scope, w, AggMode::Forbidden)?, &mut conjuncts);
    }

    // Select list
    let mut items = Vec::new();
    let mut aliases: Vec<Option<String>> = Vec::new();
    for item in &sel.items {
        match item {
            SelectItem::Star => {
                if scope.tables.is_empty() {
                    return Err(Error::semantic("* without FROM"));
                }
                for i in 0..scope.total_columns() {
                    items.push(BExpr::Col(i));
                    aliases.push(None);
                }
            }
            SelectItem::Expr { expr, alias } => {
                items.push(bind_expr(&scope, expr, AggMode::Allowed)?);
                aliases.push(alias.clone());
            }
        }
    }

    // GROUP BY / HAVING
    let group_cols = sel
        .group_by
        .iter()
        .map(|c| scope.resolve(c))
        .collect::<Result<Vec<_>>>()?;
    if sel.having.is_some() && sel.group_by.is_empty() {
        return Err(Error::semantic("HAVING requires GROUP BY"));
    }
    let having = match &sel.having {
        Some(h) => Some(bind_expr(&scope, h, AggMode::Allowed)?),
        None => None,
    };

    // ORDER BY
    let mut order = Vec::new();
    for term in &sel.order_by {
        let key = match &term.expr {
            Expr::Column(ColumnRef { qualifier: None, name })
                if aliases.iter().any(|a| a.as_deref() == Some(name.as_str())) =>
            {
                let idx = aliases.iter().position(|a| a.as_deref() == Some(name.as_str()));
                OrderKey::Output(idx.unwrap())
            }
            Expr::Int(k) => {
                if *k < 1 || *k as u64 > items.len() as u64 {
                    return Err(Error::semantic("ORDER BY ordinal out of range"));
                }
                OrderKey::Output(*k as usize - 1)
            }
            other => OrderKey::Expr(bind_expr(&scope, other, AggMode::Allowed)?),
        };
        order.push(BoundOrder { key, desc: term.desc });
    }

    // Aggregate queries
    let aggregate = !group_cols.is_empty()
        || items.iter().any(BExpr::contains_agg)
        || having.as_ref().is_some_and(BExpr::contains_agg)
        || order.iter().any(|o| matches!(&o.key, OrderKey::Expr(e) if e.contains_agg()));
    if aggregate {
        for e in &items {
            check_grouped(e, &group_cols)?;
        }
        if let Some(h) = &having {
            check_grouped(h, &group_cols)?;
        }
        for o in &order {
            if let OrderKey::Expr(e) = &o.key {
                check_grouped(e, &group_cols)?;
            }
        }
    }

    Ok(BoundSelect {
        left,
        right,
        nleft,
        conjuncts,
        items,
        group_cols,
        aggregate,
        having,
        order,
        limit: sel.limit.map(|n| usize::try_from(n).unwrap_or(usize::MAX)),
        offset: sel.offset.map_or(0, |n| usize::try_from(n).unwrap_or(usize::MAX)),
    })
}
