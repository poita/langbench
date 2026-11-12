//! Syntax tree produced by the [parser](crate::parser).
//!
//! Identifiers are already folded to lower case.

/// A column's declared type. Types are declarative only.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ColumnType {
    /// `INTEGER`
    Integer,
    /// `TEXT`
    Text,
}

/// Binary operators.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[allow(missing_docs)]
pub enum BinOp {
    Add, Sub, Mul, Div, Rem,
    Eq, Ne, Lt, Le, Gt, Ge,
    And, Or,
}

/// Aggregate functions.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[allow(missing_docs)]
pub enum AggFunc {
    Count, Sum, Min, Max, Avg,
}

/// An expression.
#[derive(Debug, Clone, PartialEq)]
#[allow(missing_docs)]
pub enum Expr {
    Int(i64),
    Str(String),
    Null,
    Column(ColumnRef),
    Neg(Box<Expr>),
    Not(Box<Expr>),
    Binary { op: BinOp, lhs: Box<Expr>, rhs: Box<Expr> },
    IsNull { expr: Box<Expr>, negated: bool },
    Like { expr: Box<Expr>, pattern: Box<Expr>, negated: bool },
    /// `arg` is `None` for `COUNT(*)`.
    Aggregate { func: AggFunc, arg: Option<Box<Expr>> },
}

/// `name` or `qualifier.name`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ColumnRef {
    /// Table name or alias, if written.
    pub qualifier: Option<String>,
    /// Column name.
    pub name: String,
}

/// An item of the select list.
#[derive(Debug, Clone, PartialEq)]
pub enum SelectItem {
    /// `*`
    Star,
    /// An expression with an optional alias.
    Expr { expr: Expr, alias: Option<String> },
}

/// `name [[AS] alias]` in a FROM clause.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TableRef {
    /// Table name.
    pub name: String,
    /// Alias, if given.
    pub alias: Option<String>,
}

/// The FROM clause: one or two tables.
#[derive(Debug, Clone, PartialEq)]
pub struct FromClause {
    /// First table.
    pub first: TableRef,
    /// Second table (comma join or `JOIN`).
    pub second: Option<TableRef>,
    /// `ON` expression of a `JOIN`.
    pub on: Option<Expr>,
}

/// One `ORDER BY` term.
#[derive(Debug, Clone, PartialEq)]
pub struct OrderTerm {
    /// The sort expression (alias or ordinal handling happens when binding).
    pub expr: Expr,
    /// `DESC` was given.
    pub desc: bool,
}

/// A `SELECT` statement.
#[derive(Debug, Clone, PartialEq)]
pub struct Select {
    /// Select list.
    pub items: Vec<SelectItem>,
    /// FROM clause.
    pub from: Option<FromClause>,
    /// WHERE expression.
    pub filter: Option<Expr>,
    /// GROUP BY columns.
    pub group_by: Vec<ColumnRef>,
    /// HAVING expression.
    pub having: Option<Expr>,
    /// ORDER BY terms.
    pub order_by: Vec<OrderTerm>,
    /// LIMIT.
    pub limit: Option<u64>,
    /// OFFSET.
    pub offset: Option<u64>,
}

/// A statement.
#[derive(Debug, Clone, PartialEq)]
#[allow(missing_docs)]
pub enum Statement {
    CreateTable { name: String, columns: Vec<(String, ColumnType)> },
    Insert { table: String, rows: Vec<Vec<Expr>> },
    Delete { table: String, filter: Option<Expr> },
    Update { table: String, assignments: Vec<(String, Expr)>, filter: Option<Expr> },
    Select(Box<Select>),
}
