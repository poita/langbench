//! Execution of bound statements.
//!
//! Every statement scans its tables in full. Joins use a hash join on all
//! cross-table equalities when there is at least one, and a nested loop
//! otherwise; either way pairs come out in nested-loop order.

use std::collections::HashMap;

use crate::ast::BinOp;
use crate::binder::{BExpr, BoundSelect, OrderKey};
use crate::eval::{eval, Env, Group, Source};
use crate::result::ResultSet;
use crate::table::{Row, Table};
use crate::value::Value;

fn is_true(e: &BExpr, env: &Env<'_>) -> bool {
    eval(e, env, None).truth() == Some(true)
}

/// Executes a bound `SELECT`.
pub fn exec_select(tables: &HashMap<String, Table>, q: &BoundSelect) -> ResultSet {
    let one_empty_row: Vec<Row> = vec![Vec::new()];
    let (lrows, rrows): (&[Row], &[Row]) = match (&q.left, &q.right) {
        (None, _) => (&one_empty_row, &[]),
        (Some(l), None) => (&tables[l].rows, &[]),
        (Some(l), Some(r)) => (&tables[l].rows, &tables[r].rows),
    };
    let source = Source { left: lrows, right: rrows, nleft: q.nleft };
    let candidates = candidates(q, &source);

    let mut out: Vec<(Vec<Value>, Vec<Value>)> = Vec::new();
    let mut emit = |env: &Env<'_>, group: Option<&Group<'_>>| {
        let row: Vec<Value> = q.items.iter().map(|e| eval(e, env, group)).collect();
        let keys: Vec<Value> = q
            .order
            .iter()
            .map(|o| match &o.key {
                OrderKey::Output(i) => row[*i].clone(),
                OrderKey::Expr(e) => eval(e, env, group),
            })
            .collect();
        out.push((row, keys));
    };

    if !q.aggregate {
        for &c in &candidates {
            emit(&source.env(c), None);
        }
    } else {
        for members in make_groups(q, &source, candidates) {
            let env = match members.first() {
                Some(&m) => source.env(m),
                None => Env { left: &[], right: &[], nleft: 0 },
            };
            let group = Group { source: &source, members: &members };
            if let Some(h) = &q.having {
                if eval(h, &env, Some(&group)).truth() != Some(true) {
                    continue;
                }
            }
            emit(&env, Some(&group));
        }
    }

    if !q.order.is_empty() {
        out.sort_by(|a, b| {
            for (i, o) in q.order.iter().enumerate() {
                let c = a.1[i].compare(&b.1[i]);
                let c = if o.desc { c.reverse() } else { c };
                if c.is_ne() {
                    return c;
                }
            }
            std::cmp::Ordering::Equal
        });
    }
    let rows = out
        .into_iter()
        .skip(q.offset)
        .take(q.limit.unwrap_or(usize::MAX))
        .map(|(row, _)| row)
        .collect();
    ResultSet { rows }
}

type Candidate = (usize, usize);

/// Groups candidates; groups come out ordered by their grouping values.
fn make_groups(
    q: &BoundSelect,
    source: &Source<'_>,
    candidates: Vec<(usize, usize)>,
) -> Vec<Vec<(usize, usize)>> {
    if q.group_cols.is_empty() {
        return vec![candidates];
    }
    let mut index: HashMap<Vec<Value>, usize> = HashMap::new();
    let mut groups: Vec<(Vec<Value>, Vec<Candidate>)> = Vec::new();
    for c in candidates {
        let env = source.env(c);
        let key: Vec<Value> = q.group_cols.iter().map(|&i| env.get(i).clone()).collect();
        match index.get(&key) {
            Some(&g) => groups[g].1.push(c),
            None => {
                index.insert(key.clone(), groups.len());
                groups.push((key, vec![c]));
            }
        }
    }
    groups.sort_by(|a, b| {
        a.0.iter()
            .zip(&b.0)
            .map(|(x, y)| x.compare(y))
            .find(|c| c.is_ne())
            .unwrap_or(std::cmp::Ordering::Equal)
    });
    groups.into_iter().map(|g| g.1).collect()
}

/// Produces the `(left index, right index)` pairs that satisfy every
/// WHERE/ON conjunct, in nested-loop order. With a single table (or none)
/// the right index is always 0.
fn candidates(q: &BoundSelect, source: &Source<'_>) -> Vec<(usize, usize)> {
    let nleft = q.nleft;
    let two_tables = q.right.is_some();

    let mut left_filters: Vec<&BExpr> = Vec::new();
    let mut right_filters: Vec<&BExpr> = Vec::new();
    let mut equi: Vec<(&BExpr, &BExpr)> = Vec::new(); // (left-side, right-side)
    let mut residual: Vec<&BExpr> = Vec::new();
    for c in &q.conjuncts {
        match c.table_mask(nleft) {
            0 | 1 => left_filters.push(c),
            2 => right_filters.push(c),
            _ => match c {
                BExpr::Binary(BinOp::Eq, a, b) => {
                    match (a.table_mask(nleft), b.table_mask(nleft)) {
                        (1, 2) => equi.push((a, b)),
                        (2, 1) => equi.push((b, a)),
                        _ => residual.push(c),
                    }
                }
                _ => residual.push(c),
            },
        }
    }

    let lkeep: Vec<usize> = (0..source.left.len())
        .filter(|&i| {
            let env = Env { left: &source.left[i], right: &[], nleft };
            left_filters.iter().all(|f| is_true(f, &env))
        })
        .collect();
    if !two_tables {
        return lkeep.into_iter().map(|i| (i, 0)).collect();
    }
    let rkeep: Vec<usize> = (0..source.right.len())
        .filter(|&j| {
            let env = Env { left: &[], right: &source.right[j], nleft };
            right_filters.iter().all(|f| is_true(f, &env))
        })
        .collect();

    let mut out = Vec::new();
    let residual_ok = |pair: (usize, usize)| {
        let env = source.env(pair);
        residual.iter().all(|f| is_true(f, &env))
    };

    if equi.is_empty() {
        for &i in &lkeep {
            for &j in &rkeep {
                if residual_ok((i, j)) {
                    out.push((i, j));
                }
            }
        }
        return out;
    }

    // Hash join: build on the (filtered) right table, probe in left order.
    let key_of = |env: &Env<'_>, right_side: bool| -> Option<Vec<Value>> {
        let mut key = Vec::with_capacity(equi.len());
        for (l, r) in &equi {
            let v = eval(if right_side { r } else { l }, env, None);
            if v.is_null() {
                return None; // NULL = anything is never true
            }
            key.push(v);
        }
        Some(key)
    };
    let mut map: HashMap<Vec<Value>, Vec<usize>> = HashMap::new();
    for &j in &rkeep {
        let env = Env { left: &[], right: &source.right[j], nleft };
        if let Some(k) = key_of(&env, true) {
            map.entry(k).or_default().push(j);
        }
    }
    for &i in &lkeep {
        let env = Env { left: &source.left[i], right: &[], nleft };
        let Some(k) = key_of(&env, false) else { continue };
        if let Some(js) = map.get(&k) {
            for &j in js {
                if residual_ok((i, j)) {
                    out.push((i, j));
                }
            }
        }
    }
    out
}

/// Deletes the rows for which `filter` is true (all rows without a filter).
pub fn exec_delete(table: &mut Table, filter: Option<&BExpr>) {
    let Some(filter) = filter else {
        table.rows.clear();
        return;
    };
    let nleft = table.columns.len();
    let keep: Vec<bool> = table
        .rows
        .iter()
        .map(|row| !is_true(filter, &Env { left: row, right: &[], nleft }))
        .collect();
    let mut keep = keep.into_iter();
    table.rows.retain(|_| keep.next().unwrap());
}

/// Applies `assignments` (column position, expression) to matching rows.
/// All right-hand sides see the row's old values.
pub fn exec_update(table: &mut Table, assignments: &[(usize, BExpr)], filter: Option<&BExpr>) {
    let nleft = table.columns.len();
    for row in &mut table.rows {
        let env = Env { left: row, right: &[], nleft };
        if filter.is_some_and(|f| !is_true(f, &env)) {
            continue;
        }
        let new: Vec<Value> = assignments.iter().map(|(_, e)| eval(e, &env, None)).collect();
        for ((col, _), v) in assignments.iter().zip(new) {
            row[*col] = v;
        }
    }
}
