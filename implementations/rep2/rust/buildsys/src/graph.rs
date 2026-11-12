//! The dependency graph over steps, phony targets and source files: whole-graph
//! validation, target resolution, cycle detection and reachability.

use std::collections::{HashMap, HashSet};

use crate::error::{Error, ErrorKind, Result};
use crate::step::{Phony, Step};
use crate::workspace::Workspace;

/// The kind of a graph node.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NodeKind {
    /// A build step (the payload is its serial, which equals the node id).
    Step(usize),
    /// A phony target (index into the phony table).
    Phony(usize),
    /// An existing workspace file that no step produces.
    Source,
}

/// A graph node.
#[derive(Debug, Clone)]
pub struct Node {
    pub kind: NodeKind,
    /// Name used in messages: primary output, `@name`, or the path.
    pub name: String,
    /// Ordering dependencies in order (duplicates kept).
    pub deps: Vec<usize>,
    /// Ordering dependencies with duplicates removed.
    pub succ: Vec<usize>,
}

/// The build graph. Step `i` is always node `i`.
#[derive(Debug)]
pub struct Graph {
    nodes: Vec<Node>,
    outputs: HashMap<String, usize>,
    phony_ids: HashMap<String, usize>,
    sources: HashMap<String, usize>,
}

fn missing(target: &str, by: &str) -> Error {
    Error::new(
        ErrorKind::MissingInput,
        format!("{target} required by {by}"),
    )
}

impl Graph {
    /// Builds the graph and performs whole-graph validation: duplicate
    /// outputs, then reference resolution for steps and phonies.
    pub fn build(steps: &[Step], phonies: &[Phony], ws: &Workspace) -> Result<Graph> {
        let mut g = Graph {
            nodes: Vec::new(),
            outputs: HashMap::new(),
            phony_ids: HashMap::new(),
            sources: HashMap::new(),
        };
        for (i, s) in steps.iter().enumerate() {
            for o in &s.full_outputs {
                if g.outputs.insert(o.clone(), i).is_some() {
                    return Err(Error::new(ErrorKind::DupOutput, o.as_str()));
                }
            }
            g.nodes.push(Node {
                kind: NodeKind::Step(i),
                name: s.primary().to_string(),
                deps: Vec::new(),
                succ: Vec::new(),
            });
        }
        for (i, p) in phonies.iter().enumerate() {
            g.phony_ids.insert(p.name.clone(), g.nodes.len());
            g.nodes.push(Node {
                kind: NodeKind::Phony(i),
                name: format!("@{}", p.name),
                deps: Vec::new(),
                succ: Vec::new(),
            });
        }
        for (i, s) in steps.iter().enumerate() {
            let mut deps = Vec::new();
            for t in s.inputs.iter().chain(&s.after) {
                let n = g
                    .resolve(t.as_bytes(), ws)
                    .ok_or_else(|| missing(t, s.primary()))?;
                deps.push(n);
            }
            g.nodes[i].deps = deps;
        }
        for p in phonies {
            let id = g.phony_ids[&p.name];
            let mut deps = Vec::new();
            for t in &p.deps {
                let n = g
                    .resolve(t.as_bytes(), ws)
                    .ok_or_else(|| missing(t, &format!("@{}", p.name)))?;
                deps.push(n);
            }
            g.nodes[id].deps = deps;
        }
        for n in &mut g.nodes {
            let mut seen = HashSet::new();
            n.succ = n.deps.iter().copied().filter(|d| seen.insert(*d)).collect();
        }
        Ok(g)
    }

    /// Resolves a target reference to a node, creating a source node on
    /// first use. `None` if the reference names nothing.
    pub fn resolve(&mut self, target: &[u8], ws: &Workspace) -> Option<usize> {
        let t = std::str::from_utf8(target).ok()?;
        if let Some(name) = t.strip_prefix('@') {
            return self.phony_ids.get(name).copied();
        }
        if let Some(&i) = self.outputs.get(t) {
            return Some(i);
        }
        if let Some(&i) = self.sources.get(t) {
            return Some(i);
        }
        if ws.contains(t) {
            let id = self.nodes.len();
            self.nodes.push(Node {
                kind: NodeKind::Source,
                name: t.to_string(),
                deps: Vec::new(),
                succ: Vec::new(),
            });
            self.sources.insert(t.to_string(), id);
            return Some(id);
        }
        None
    }

    /// All nodes.
    pub fn nodes(&self) -> &[Node] {
        &self.nodes
    }

    /// Searches for cycles from `roots` using the specified depth-first
    /// search; on success returns the reachable set as a membership vector.
    pub fn reachable(&self, roots: &[usize]) -> Result<Vec<bool>> {
        const WHITE: u8 = 0;
        const GREY: u8 = 1;
        const BLACK: u8 = 2;
        let mut colour = vec![WHITE; self.nodes.len()];
        for &root in roots {
            if colour[root] != WHITE {
                continue;
            }
            colour[root] = GREY;
            let mut stack: Vec<(usize, usize)> = vec![(root, 0)];
            while let Some(&(n, i)) = stack.last() {
                let succ = &self.nodes[n].succ;
                if i < succ.len() {
                    stack.last_mut().unwrap().1 = i + 1;
                    let m = succ[i];
                    if colour[m] == GREY {
                        let j = stack.iter().position(|&(x, _)| x == m).unwrap();
                        let mut names: Vec<&str> = stack[j..]
                            .iter()
                            .map(|&(x, _)| self.nodes[x].name.as_str())
                            .collect();
                        names.push(&self.nodes[m].name);
                        return Err(Error::new(ErrorKind::Cycle, names.join(" -> ")));
                    }
                    if colour[m] == WHITE {
                        colour[m] = GREY;
                        stack.push((m, 0));
                    }
                } else {
                    colour[n] = BLACK;
                    stack.pop();
                }
            }
        }
        Ok(colour.into_iter().map(|c| c != WHITE).collect())
    }
}
