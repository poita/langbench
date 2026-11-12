//! The dependency graph: node resolution, whole-graph validation, requested
//! targets, cycle detection and reachability.
//!
//! Node ids: step `i` is node `i`; phony `j` is node `S + j`; source nodes
//! are appended after them as they are first referenced.

use crate::error::{Error, ErrorKind, Result};
use crate::eval::Config;
use crate::workspace::Workspace;
use std::collections::{HashMap, HashSet};

/// What a graph node stands for.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum NodeKind {
    Step(usize),
    Phony(usize),
    Source(Vec<u8>),
}

/// The resolved dependency graph of one build.
#[derive(Debug)]
pub struct Graph {
    pub kinds: Vec<NodeKind>,
    /// Successor lists: ordering dependencies, duplicates removed.
    pub succ: Vec<Vec<usize>>,
    outputs: HashMap<Vec<u8>, usize>,
    phonies: HashMap<Vec<u8>, usize>,
    sources: HashMap<Vec<u8>, usize>,
}

fn dedup_keep_first(v: Vec<usize>) -> Vec<usize> {
    let mut seen = HashSet::with_capacity(v.len());
    v.into_iter().filter(|n| seen.insert(*n)).collect()
}

impl Graph {
    /// Builds the graph and runs the whole-graph validation: duplicate
    /// outputs, reference resolution, then the default list.
    pub fn new(config: &Config, ws: &Workspace) -> Result<Graph> {
        let s = config.steps.len();
        let mut kinds: Vec<NodeKind> = (0..s).map(NodeKind::Step).collect();
        kinds.extend((0..config.phonies.len()).map(NodeKind::Phony));
        let mut g = Graph {
            succ: vec![Vec::new(); kinds.len()],
            kinds,
            outputs: HashMap::new(),
            phonies: HashMap::new(),
            sources: HashMap::new(),
        };
        for (i, step) in config.steps.iter().enumerate() {
            for out in &step.full_outputs {
                if g.outputs.insert(out.clone(), i).is_some() {
                    return Err(Error::new(ErrorKind::DupOutput, out.clone()));
                }
            }
        }
        for (j, p) in config.phonies.iter().enumerate() {
            g.phonies.insert(p.name.as_bytes().to_vec(), s + j);
        }
        for (i, step) in config.steps.iter().enumerate() {
            let mut deps = Vec::new();
            for r in step.inputs.iter().chain(step.after.iter()) {
                match g.resolve(ws, r) {
                    Some(n) => deps.push(n),
                    None => {
                        let mut d = r.clone();
                        d.extend_from_slice(b" required by ");
                        d.extend_from_slice(step.primary());
                        return Err(Error::new(ErrorKind::MissingInput, d));
                    }
                }
            }
            g.succ[i] = dedup_keep_first(deps);
        }
        for (j, p) in config.phonies.iter().enumerate() {
            let mut deps = Vec::new();
            for r in &p.deps {
                match g.resolve(ws, r) {
                    Some(n) => deps.push(n),
                    None => {
                        let mut d = r.clone();
                        d.extend_from_slice(b" required by @");
                        d.extend_from_slice(p.name.as_bytes());
                        return Err(Error::new(ErrorKind::MissingInput, d));
                    }
                }
            }
            g.succ[s + j] = dedup_keep_first(deps);
        }
        for t in &config.defaults {
            g.resolve_target(ws, t)?;
        }
        Ok(g)
    }

    /// Resolves a reference: a phony (`@name`), a step output, or a source
    /// file, in that order of precedence.
    fn resolve(&mut self, ws: &Workspace, r: &[u8]) -> Option<usize> {
        if let Some(name) = r.strip_prefix(b"@") {
            return self.phonies.get(name).copied();
        }
        if let Some(&i) = self.outputs.get(r) {
            return Some(i);
        }
        if let Some(&n) = self.sources.get(r) {
            return Some(n);
        }
        if ws.contains(r) {
            let id = self.kinds.len();
            self.kinds.push(NodeKind::Source(r.to_vec()));
            self.succ.push(Vec::new());
            self.sources.insert(r.to_vec(), id);
            return Some(id);
        }
        None
    }

    fn resolve_target(&mut self, ws: &Workspace, t: &[u8]) -> Result<usize> {
        self.resolve(ws, t).ok_or_else(|| Error::new(ErrorKind::UnknownTarget, t))
    }

    /// Resolves the requested targets (the build line's, or else the
    /// defaults), removing duplicates.
    pub fn requested(&mut self, ws: &Workspace, config: &Config, targets: &[Vec<u8>]) -> Result<Vec<usize>> {
        let names: &[Vec<u8>] = if targets.is_empty() { &config.defaults } else { targets };
        let mut seen: HashSet<&[u8]> = HashSet::new();
        let unique: Vec<&Vec<u8>> = names.iter().filter(|n| seen.insert(n.as_slice())).collect();
        if unique.is_empty() {
            return Err(Error::bare(ErrorKind::NoDefault));
        }
        let mut roots = Vec::with_capacity(unique.len());
        for t in unique {
            roots.push(self.resolve_target(ws, t)?);
        }
        Ok(roots)
    }

    /// A node's name in messages.
    pub fn node_name(&self, config: &Config, n: usize) -> Vec<u8> {
        match &self.kinds[n] {
            NodeKind::Step(i) => config.steps[*i].primary().to_vec(),
            NodeKind::Phony(j) => {
                let mut v = b"@".to_vec();
                v.extend_from_slice(config.phonies[*j].name.as_bytes());
                v
            }
            NodeKind::Source(p) => p.clone(),
        }
    }

    /// Depth-first cycle search from the roots; on success returns which
    /// nodes are reachable.
    pub fn reachable(&self, config: &Config, roots: &[usize]) -> Result<Vec<bool>> {
        const WHITE: u8 = 0;
        const GREY: u8 = 1;
        const BLACK: u8 = 2;
        let mut colour = vec![WHITE; self.kinds.len()];
        for &root in roots {
            if colour[root] != WHITE {
                continue;
            }
            colour[root] = GREY;
            let mut stack: Vec<(usize, usize)> = vec![(root, 0)];
            while let Some(&(n, i)) = stack.last() {
                if i < self.succ[n].len() {
                    let top = stack.len() - 1;
                    stack[top].1 = i + 1;
                    let m = self.succ[n][i];
                    if colour[m] == GREY {
                        let j = stack.iter().position(|&(x, _)| x == m).expect("grey nodes are on the stack");
                        let mut names: Vec<Vec<u8>> = stack[j..].iter().map(|&(x, _)| self.node_name(config, x)).collect();
                        names.push(self.node_name(config, m));
                        return Err(Error::new(ErrorKind::Cycle, names.join(&b" -> "[..])));
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
