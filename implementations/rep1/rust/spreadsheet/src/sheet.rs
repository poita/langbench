//! The sheet: cell storage, the dependency graph and incremental recalculation.
//!
//! Each cell stores its content, its current value, the cells it reads
//! (`deps`) and the cells that read it (`dependents`). After every edit the
//! set `A` of cells that transitively read the edited cell is found by
//! walking `dependents`; Tarjan's algorithm runs over the subgraph induced by
//! `A`, emitting strongly connected components dependencies-first. Cyclic
//! components get `#CYCLE!`; every other cell is evaluated from the stored
//! values of the cells it reads. Nothing outside `A` is touched.

use crate::ast::Expr;
use crate::cell::CellRef;
use crate::error::Error;
use crate::eval::{evaluate, CellSource};
use crate::graph::strongly_connected_components;
use crate::parser::parse_formula;
use crate::value::{ErrorCode, Value};
use std::collections::{HashMap, HashSet};
use std::hash::{BuildHasherDefault, Hasher};
use std::rc::Rc;

/// What a cell holds.
#[derive(Clone, PartialEq, Debug)]
pub enum Content {
    /// Nothing.
    Empty,
    /// A number literal.
    Number(f64),
    /// A string literal.
    Text(Rc<str>),
    /// A parsed formula.
    Formula(Expr),
}

impl Content {
    /// Interprets the text of a `set` command: a formula (`=...`), a string
    /// literal (`"..."`) or a number literal (`-?[0-9]+(\.[0-9]+)?`).
    ///
    /// ```
    /// use spreadsheet::Content;
    /// assert!(matches!(Content::parse("=1+2").unwrap(), Content::Formula(_)));
    /// assert!(matches!(Content::parse("\"hi\"").unwrap(), Content::Text(_)));
    /// assert_eq!(Content::parse("4.50").unwrap(), Content::Number(4.5));
    /// assert!(Content::parse("hello").is_err());
    /// ```
    pub fn parse(text: &str) -> Result<Content, Error> {
        if let Some(formula) = text.strip_prefix('=') {
            return Ok(Content::Formula(parse_formula(formula)?));
        }
        if let Some(rest) = text.strip_prefix('"') {
            return match rest.strip_suffix('"') {
                Some(s) if !s.contains('"') => Ok(Content::Text(Rc::from(s))),
                _ => Err(Error::InvalidContent(text.to_string())),
            };
        }
        let invalid = || Error::InvalidContent(text.to_string());
        let body = text.strip_prefix('-').unwrap_or(text);
        let (int, frac) = match body.split_once('.') {
            Some((i, f)) => (i, Some(f)),
            None => (body, None),
        };
        let digits = |s: &str| !s.is_empty() && s.bytes().all(|b| b.is_ascii_digit());
        if !digits(int) || frac.is_some_and(|f| !digits(f)) {
            return Err(invalid());
        }
        let n: f64 = text.parse().map_err(|_| invalid())?;
        if !n.is_finite() {
            return Err(invalid());
        }
        // `-0` is the number zero.
        Ok(Content::Number(if n == 0.0 { 0.0 } else { n }))
    }
}

#[derive(Default)]
struct KeyHasher(u64);

impl Hasher for KeyHasher {
    fn finish(&self) -> u64 {
        self.0 ^ (self.0 >> 32)
    }
    fn write(&mut self, bytes: &[u8]) {
        for &b in bytes {
            self.0 = (self.0 ^ b as u64).wrapping_mul(0x100_0000_01b3);
        }
    }
    fn write_u32(&mut self, n: u32) {
        self.0 = (n as u64).wrapping_mul(0x9E37_79B9_7F4A_7C15);
    }
}

type FastMap<V> = HashMap<u32, V, BuildHasherDefault<KeyHasher>>;
type FastSet = HashSet<u32, BuildHasherDefault<KeyHasher>>;

struct Cell {
    content: Content,
    value: Value,
    /// Keys of the cells this cell's formula reads (deduplicated).
    deps: Vec<u32>,
    /// Keys of the cells whose formulas read this cell.
    dependents: FastSet,
}

impl Cell {
    fn new() -> Cell {
        Cell { content: Content::Empty, value: Value::Empty, deps: Vec::new(), dependents: FastSet::default() }
    }
}

#[derive(Default)]
struct Cells(FastMap<Cell>);

impl CellSource for Cells {
    fn value(&self, cell: CellRef) -> Value {
        self.0.get(&cell.key()).map_or(Value::Empty, |c| c.value.clone())
    }
}

/// A spreadsheet.
///
/// All mutation goes through [`set`](Sheet::set) / [`clear`](Sheet::clear)
/// (or their string-based variants); each call leaves every formula cell
/// holding the value its formula evaluates to against the current sheet.
#[derive(Default)]
pub struct Sheet {
    cells: Cells,
}

impl Sheet {
    /// Creates an empty sheet.
    pub fn new() -> Sheet {
        Sheet::default()
    }

    /// Replaces the content of `cell` and recalculates every cell that
    /// depends on it, directly or indirectly.
    pub fn set(&mut self, cell: CellRef, content: Content) {
        let key = cell.key();
        // Drop the reverse edges of the previous formula.
        let old_deps = std::mem::take(&mut self.cells.0.entry(key).or_insert_with(Cell::new).deps);
        for d in old_deps {
            if let Some(c) = self.cells.0.get_mut(&d) {
                c.dependents.remove(&key);
            }
        }
        let mut deps = Vec::new();
        if let Content::Formula(expr) = &content {
            let mut refs = Vec::new();
            expr.collect_dependencies(&mut refs);
            deps = refs.into_iter().map(CellRef::key).collect();
            deps.sort_unstable();
            deps.dedup();
            for &d in &deps {
                self.cells.0.entry(d).or_insert_with(Cell::new).dependents.insert(key);
            }
        }
        let c = self.cells.0.get_mut(&key).expect("cell exists");
        c.content = content;
        c.deps = deps;
        self.recalculate(key);
    }

    /// Makes `cell` empty.
    pub fn clear(&mut self, cell: CellRef) {
        self.set(cell, Content::Empty);
    }

    /// Parses `content` (see [`Content::parse`]) and stores it in the cell
    /// named `cell`. The sheet is unchanged if either argument is invalid.
    pub fn set_content(&mut self, cell: &str, content: &str) -> Result<(), Error> {
        let cell = CellRef::parse(cell).ok_or_else(|| Error::InvalidCell(cell.to_string()))?;
        let content = Content::parse(content)?;
        self.set(cell, content);
        Ok(())
    }

    /// The current value of a cell; [`Value::Empty`] if it is empty.
    pub fn get(&self, cell: CellRef) -> Value {
        self.cells.value(cell)
    }

    /// The displayed text of the cell named `cell` (empty for an empty cell).
    pub fn display(&self, cell: &str) -> Result<String, Error> {
        let cell = CellRef::parse(cell).ok_or_else(|| Error::InvalidCell(cell.to_string()))?;
        Ok(self.get(cell).to_string())
    }

    /// Every non-empty cell with its value, in row-major order.
    pub fn dump(&self) -> Vec<(CellRef, Value)> {
        let mut out: Vec<(u32, &Cell)> = self
            .cells
            .0
            .iter()
            .filter(|(_, c)| c.content != Content::Empty)
            .map(|(&k, c)| (k, c))
            .collect();
        out.sort_unstable_by_key(|&(k, _)| k);
        out.into_iter().map(|(k, c)| (CellRef::from_key(k), c.value.clone())).collect()
    }

    /// Recomputes the edited cell and everything that depends on it.
    fn recalculate(&mut self, start: u32) {
        // Collect the affected set A by following reverse edges. While doing
        // so, record the edges of the induced subgraph in the direction
        // "cell -> cell it reads": `adj[v]` lists the members of A that `v` reads.
        let mut order: Vec<u32> = vec![start];
        let mut position: FastMap<usize> = FastMap::default();
        position.insert(start, 0);
        let mut adj: Vec<Vec<u32>> = vec![Vec::new()];
        let mut i = 0;
        while i < order.len() {
            let u = order[i];
            for &v in &self.cells.0[&u].dependents {
                let vi = *position.entry(v).or_insert_with(|| {
                    order.push(v);
                    adj.push(Vec::new());
                    order.len() - 1
                });
                adj[vi].push(i as u32);
            }
            i += 1;
        }

        strongly_connected_components(&adj, |scc| {
            let cyclic = scc.len() > 1 || adj[scc[0]].contains(&(scc[0] as u32));
            for &n in scc {
                let key = order[n];
                let value = if cyclic { Value::Error(ErrorCode::Cycle) } else { self.compute(key) };
                self.cells.0.get_mut(&key).expect("affected cell exists").value = value;
            }
        });
    }

    /// Evaluates the cell's content against the stored values of other cells.
    fn compute(&self, key: u32) -> Value {
        match &self.cells.0[&key].content {
            Content::Empty => Value::Empty,
            Content::Number(n) => Value::Number(*n),
            Content::Text(s) => Value::Str(s.clone()),
            Content::Formula(expr) => match evaluate(expr, &self.cells) {
                Value::Empty => Value::Number(0.0),
                v => v,
            },
        }
    }
}
