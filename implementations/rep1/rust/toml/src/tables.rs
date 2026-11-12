//! The table-resolution layer: the working tree used while decoding, which
//! carries the explicit / implicit / dotted / inline flags of TOML 1.0.0 §1.3
//! and enforces the rules for headers and dotted keys.

use std::collections::btree_map::Entry;
use std::collections::BTreeMap;

use crate::value::{Scalar, Table, Value};

/// How a table came into existence.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum State {
    /// Created only as an intermediate segment of a header.
    Implicit,
    /// Opened by a `[header]` / `[[header]]` line.
    Explicit,
    /// Created as an intermediate segment of a dotted key.
    Dotted,
    /// An inline-table literal (closed: nothing may be added later).
    Inline,
}

pub(crate) enum Node {
    Scalar(Scalar),
    Array(ArrayNode),
    Table(TableNode),
}

pub(crate) struct ArrayNode {
    pub items: Vec<Node>,
    /// True for arrays created by `[[ … ]]` headers, false for literals.
    pub of_tables: bool,
}

pub(crate) struct TableNode {
    pub map: BTreeMap<String, Node>,
    pub state: State,
}

/// A violation of the table-definition rules.
#[derive(Debug)]
pub(crate) struct Conflict(pub &'static str);

type Res<T> = Result<T, Conflict>;

fn as_table_mut(node: &mut Node) -> Option<&mut TableNode> {
    match node {
        Node::Table(t) => Some(t),
        _ => None,
    }
}

impl TableNode {
    pub fn new(state: State) -> Self {
        TableNode {
            map: BTreeMap::new(),
            state,
        }
    }

    /// One segment of a header path (an intermediate one): create it
    /// implicitly if missing, otherwise pass through a table or the last
    /// element of an array of tables.
    fn step_header(&mut self, seg: &str) -> Res<&mut TableNode> {
        match self.map.entry(seg.to_owned()) {
            Entry::Vacant(v) => {
                let node = v.insert(Node::Table(TableNode::new(State::Implicit)));
                as_table_mut(node).ok_or(Conflict("internal error"))
            }
            Entry::Occupied(o) => match o.into_mut() {
                Node::Table(t) if t.state != State::Inline => Ok(t),
                Node::Table(_) => Err(Conflict("cannot extend an inline table")),
                Node::Array(a) if a.of_tables => match a.items.last_mut() {
                    Some(Node::Table(t)) => Ok(t),
                    _ => Err(Conflict("internal error")),
                },
                _ => Err(Conflict("key is not a table")),
            },
        }
    }

    /// One intermediate segment of a dotted key.
    fn step_dotted(&mut self, seg: &str) -> Res<&mut TableNode> {
        match self.map.entry(seg.to_owned()) {
            Entry::Vacant(v) => {
                let node = v.insert(Node::Table(TableNode::new(State::Dotted)));
                as_table_mut(node).ok_or(Conflict("internal error"))
            }
            Entry::Occupied(o) => match o.into_mut() {
                Node::Table(t) if matches!(t.state, State::Implicit | State::Dotted) => Ok(t),
                Node::Table(_) => Err(Conflict("dotted key reaches into a defined table")),
                _ => Err(Conflict("key is not a table")),
            },
        }
    }

    /// Handles `[a.b.c]`: returns the table that following pairs belong to.
    pub fn open_table(&mut self, path: &[String]) -> Res<&mut TableNode> {
        let (last, parents) = path.split_last().ok_or(Conflict("empty key"))?;
        let mut cur = self;
        for seg in parents {
            cur = cur.step_header(seg)?;
        }
        match cur.map.entry(last.clone()) {
            Entry::Vacant(v) => {
                let node = v.insert(Node::Table(TableNode::new(State::Explicit)));
                as_table_mut(node).ok_or(Conflict("internal error"))
            }
            Entry::Occupied(o) => match o.into_mut() {
                Node::Table(t) if t.state == State::Implicit => {
                    t.state = State::Explicit;
                    Ok(t)
                }
                _ => Err(Conflict("table is already defined")),
            },
        }
    }

    /// Handles `[[a.b.c]]`: appends a new element and returns it.
    pub fn open_array_table(&mut self, path: &[String]) -> Res<&mut TableNode> {
        let (last, parents) = path.split_last().ok_or(Conflict("empty key"))?;
        let mut cur = self;
        for seg in parents {
            cur = cur.step_header(seg)?;
        }
        let element = Node::Table(TableNode::new(State::Explicit));
        match cur.map.entry(last.clone()) {
            Entry::Vacant(v) => {
                let node = v.insert(Node::Array(ArrayNode {
                    items: vec![element],
                    of_tables: true,
                }));
                match node {
                    Node::Array(a) => a.items.last_mut().and_then(as_table_mut),
                    _ => None,
                }
                .ok_or(Conflict("internal error"))
            }
            Entry::Occupied(o) => match o.into_mut() {
                Node::Array(a) if a.of_tables => {
                    a.items.push(element);
                    a.items
                        .last_mut()
                        .and_then(as_table_mut)
                        .ok_or(Conflict("internal error"))
                }
                _ => Err(Conflict("key is not an array of tables")),
            },
        }
    }

    /// Handles `a.b.c = value` in this table.
    pub fn insert_dotted(&mut self, path: &[String], value: Node) -> Res<()> {
        let (last, parents) = path.split_last().ok_or(Conflict("empty key"))?;
        let mut cur = self;
        for seg in parents {
            cur = cur.step_dotted(seg)?;
        }
        match cur.map.entry(last.clone()) {
            Entry::Vacant(v) => {
                v.insert(value);
                Ok(())
            }
            Entry::Occupied(_) => Err(Conflict("duplicate key")),
        }
    }
}

impl Node {
    /// Converts the working tree into the public [`Value`] tree.
    pub fn into_value(self) -> Value {
        match self {
            Node::Scalar(s) => Value::Scalar(s),
            Node::Array(a) => Value::Array(a.items.into_iter().map(Node::into_value).collect()),
            Node::Table(t) => Value::Table(t.into_table()),
        }
    }
}

impl TableNode {
    pub fn into_table(self) -> Table {
        self.map
            .into_iter()
            .map(|(k, v)| (k, v.into_value()))
            .collect()
    }
}
