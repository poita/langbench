//! The resolution search.
//!
//! The search is the depth-first, newest-first, chronologically backtracking
//! procedure described in the crate documentation, implemented iteratively:
//!
//! * the registry is compiled once into flat arrays; every requirement's range
//!   becomes a contiguous index range over its package's versions (sorted
//!   newest first), found by binary search;
//! * the pending requirement list is a persistent singly linked list stored in
//!   an arena, so pushing a version's requirements never copies the tail;
//! * the arena and the `chosen` map are rewound on backtracking (arena
//!   truncation and a trail of chosen packages), so a step costs O(1) plus the
//!   requirements it adds, and the depth is bounded by memory, not the stack.

use crate::registry::{Registry, Requirement};
use crate::version::Version;
use std::collections::HashMap;
use std::fmt;

const NIL: u32 = u32::MAX;

/// A successful resolution: one chosen version per needed package.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Resolution {
    packages: Vec<(String, Version)>,
}

impl Resolution {
    /// The chosen `(name, version)` pairs, sorted by name in byte order.
    pub fn packages(&self) -> &[(String, Version)] {
        &self.packages
    }

    /// The version chosen for `name`, if it is part of the resolution.
    pub fn get(&self, name: &str) -> Option<Version> {
        self.packages
            .binary_search_by(|(n, _)| n.as_str().cmp(name))
            .ok()
            .map(|i| self.packages[i].1)
    }

    /// Number of packages in the resolution.
    pub fn len(&self) -> usize {
        self.packages.len()
    }

    /// True if no package is needed.
    pub fn is_empty(&self) -> bool {
        self.packages.is_empty()
    }
}

impl fmt::Display for Resolution {
    /// One `name version` line per package, each terminated by `\n`.
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        for (name, version) in &self.packages {
            writeln!(f, "{name} {version}")?;
        }
        Ok(())
    }
}

/// A requirement compiled to an index range into its package's candidates.
#[derive(Clone, Copy)]
struct CReq {
    pkg: u32,
    /// Candidate indices `start..end` (0 is the newest version).
    start: u32,
    end: u32,
}

struct CVersion {
    version: Version,
    reqs_start: u32,
    reqs_end: u32,
}

/// A node of the persistent pending list.
#[derive(Clone, Copy)]
struct Node {
    req: u32,
    next: u32,
}

/// A choice point.
struct Frame {
    pkg: u32,
    /// Candidate index currently being tried.
    cur: u32,
    end: u32,
    /// Pending list that follows the requirement that created this frame.
    rest: u32,
    arena_len: u32,
    trail_len: u32,
}

struct Compiled {
    names: Vec<String>,
    /// For each package, its versions (newest first) in `versions[a..b]`.
    spans: Vec<(u32, u32)>,
    versions: Vec<CVersion>,
    reqs: Vec<CReq>,
    root: (u32, u32),
}

fn compile(registry: &Registry, root: &[Requirement]) -> Compiled {
    let mut ids: HashMap<&str, u32> = HashMap::new();
    let mut names: Vec<String> = Vec::new();
    // Packages with releases get ids first.
    let mut pkgs: Vec<(&String, &Vec<crate::registry::Release>)> = registry.packages().collect();
    pkgs.sort_by(|a, b| a.0.cmp(b.0));
    for (name, _) in &pkgs {
        ids.insert(name.as_str(), names.len() as u32);
        names.push((*name).clone());
    }
    // Requirement targets that have no releases get ids with no versions.
    let mut extra: Vec<&str> = Vec::new();
    let all_reqs = pkgs
        .iter()
        .flat_map(|(_, rels)| rels.iter().flat_map(|r| r.requirements.iter()))
        .chain(root.iter());
    for r in all_reqs {
        if !ids.contains_key(r.name.as_str()) {
            ids.insert(r.name.as_str(), (names.len() + extra.len()) as u32);
            extra.push(r.name.as_str());
        }
    }
    names.extend(extra.iter().map(|s| s.to_string()));
    let npkg = names.len();

    // Sort each package's versions newest first and lay them out flat.
    let mut spans = vec![(0u32, 0u32); npkg];
    let mut versions: Vec<CVersion> = Vec::new();
    let mut reqs: Vec<CReq> = Vec::new();
    // Per package: the sorted keys of its versions, for binary search.
    let mut keys: Vec<Vec<u128>> = vec![Vec::new(); npkg];
    let mut pending_reqs: Vec<(&Requirement, usize)> = Vec::new();

    for (i, (_, rels)) in pkgs.iter().enumerate() {
        let mut order: Vec<&crate::registry::Release> = rels.iter().collect();
        order.sort_by(|a, b| b.version.cmp(&a.version));
        let vstart = versions.len() as u32;
        for rel in order {
            let rs = reqs.len() as u32;
            for r in &rel.requirements {
                pending_reqs.push((r, reqs.len()));
                reqs.push(CReq {
                    pkg: ids[r.name.as_str()],
                    start: 0,
                    end: 0,
                });
            }
            versions.push(CVersion {
                version: rel.version,
                reqs_start: rs,
                reqs_end: reqs.len() as u32,
            });
            keys[i].push(rel.version.key());
        }
        spans[i] = (vstart, versions.len() as u32);
    }
    let root_start = reqs.len() as u32;
    for r in root {
        pending_reqs.push((r, reqs.len()));
        reqs.push(CReq {
            pkg: ids[r.name.as_str()],
            start: 0,
            end: 0,
        });
    }
    let root_end = reqs.len() as u32;

    // Keys are in descending order: candidates for [lo, hi) are the indices
    // with key < hi (skip the prefix of keys >= hi) up to keys >= lo.
    for (r, idx) in pending_reqs {
        let (lo, hi) = r.range.bounds();
        let k = &keys[reqs[idx].pkg as usize];
        let start = k.partition_point(|&x| x >= hi);
        let end = k.partition_point(|&x| x >= lo);
        reqs[idx].start = start as u32;
        reqs[idx].end = end.max(start) as u32;
    }

    Compiled {
        names,
        spans,
        versions,
        reqs,
        root: (root_start, root_end),
    }
}

/// Resolves `root` against `registry`.
///
/// Returns the first complete solution of the search: requirements are
/// processed depth-first in the order listed, each package is fixed to the
/// newest version that satisfies the first requirement reaching it, and when
/// a later requirement fails the most recent choice with an untried candidate
/// moves to its next-newest candidate (chronological backtracking). Returns
/// `None` if the search exhausts every possibility.
///
/// The search can take exponential time on adversarial registries.
pub fn resolve(registry: &Registry, root: &[Requirement]) -> Option<Resolution> {
    let c = compile(registry, root);
    let none = u32::MAX;
    let mut chosen: Vec<u32> = vec![none; c.names.len()];
    let mut trail: Vec<u32> = Vec::new();
    let mut arena: Vec<Node> = Vec::new();
    let mut frames: Vec<Frame> = Vec::new();

    // Select candidate `idx` of `pkg`: record it and push its requirements in
    // front of `rest`, returning the new pending list.
    let enter = |pkg: u32,
                 idx: u32,
                 rest: u32,
                 chosen: &mut Vec<u32>,
                 trail: &mut Vec<u32>,
                 arena: &mut Vec<Node>|
     -> u32 {
        chosen[pkg as usize] = idx;
        trail.push(pkg);
        let v = &c.versions[(c.spans[pkg as usize].0 + idx) as usize];
        push_reqs(arena, v.reqs_start, v.reqs_end, rest)
    };

    let mut pending = push_reqs(&mut arena, c.root.0, c.root.1, NIL);
    loop {
        if pending == NIL {
            break;
        }
        let node = arena[pending as usize];
        let req = c.reqs[node.req as usize];
        let cur = chosen[req.pkg as usize];
        if cur != none {
            if req.start <= cur && cur < req.end {
                pending = node.next;
                continue;
            }
        } else if req.start < req.end {
            frames.push(Frame {
                pkg: req.pkg,
                cur: req.start,
                end: req.end,
                rest: node.next,
                arena_len: arena.len() as u32,
                trail_len: trail.len() as u32,
            });
            pending = enter(req.pkg, req.start, node.next, &mut chosen, &mut trail, &mut arena);
            continue;
        }
        // Failure: backtrack to the most recent choice with a candidate left.
        loop {
            let f = frames.last_mut()?;
            while trail.len() > f.trail_len as usize {
                chosen[trail.pop().unwrap() as usize] = none;
            }
            arena.truncate(f.arena_len as usize);
            f.cur += 1;
            if f.cur < f.end {
                pending = enter(f.pkg, f.cur, f.rest, &mut chosen, &mut trail, &mut arena);
                break;
            }
            frames.pop();
        }
    }

    let mut packages: Vec<(String, Version)> = trail
        .iter()
        .map(|&p| {
            let v = &c.versions[(c.spans[p as usize].0 + chosen[p as usize]) as usize];
            (c.names[p as usize].clone(), v.version)
        })
        .collect();
    packages.sort_by(|a, b| a.0.cmp(&b.0));
    Some(Resolution { packages })
}

fn push_reqs(arena: &mut Vec<Node>, start: u32, end: u32, rest: u32) -> u32 {
    let mut head = rest;
    for r in (start..end).rev() {
        arena.push(Node { req: r, next: head });
        head = (arena.len() - 1) as u32;
    }
    head
}
