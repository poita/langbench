//! The resolution search.
//!
//! This is a depth-first, newest-first search with chronological
//! backtracking, implemented iteratively with an explicit stack of choice
//! points so that recursion depth (which can reach tens of thousands of
//! pending requirements) is not limited by the call stack.
//!
//! Representation, chosen so that every step costs O(1) plus the
//! requirements it pushes:
//!
//! * the *pending* list is a persistent singly linked list living in an arena
//!   (`Vec<Node>`); a choice point only remembers the list head that follows
//!   its own requirement, so nothing is ever copied;
//! * the *chosen* map is a flat array indexed by package id, with a trail of
//!   assignments that is unwound when backtracking;
//! * the arena is truncated back to its size at the choice point when
//!   backtracking, so it is bounded by the live search depth;
//! * a package's candidates are a precomputed contiguous index range.

use crate::registry::{PackageId, Problem, Registry, Requirement};
use crate::version::Version;

const NIL: u32 = u32::MAX;
const UNSET: u32 = u32::MAX;

/// One cell of the shared pending list.
#[derive(Clone, Copy)]
struct Node {
    req: Requirement,
    next: u32,
}

/// A choice point: package `package` is being assigned candidates
/// `next..end` (newest-first indices), and `rest` is the pending list that
/// follows the requirement that created the choice point.
struct Choice {
    package: PackageId,
    next: u32,
    end: u32,
    rest: u32,
    arena_len: u32,
    trail_len: u32,
}

/// A successful resolution: the chosen version of every needed package.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Resolution {
    /// `(package name, version)`, sorted by name in ascending byte order.
    pub packages: Vec<(String, Version)>,
}

impl Resolution {
    /// Renders one `name version` line per package (each ending in `\n`);
    /// empty for an empty resolution.
    pub fn to_lines(&self) -> String {
        let mut out = String::new();
        for (name, v) in &self.packages {
            out.push_str(name);
            out.push(' ');
            out.push_str(&v.to_string());
            out.push('\n');
        }
        out
    }
}

/// Resolves a parsed [`Problem`]: returns the first complete solution of the
/// specified search, or `None` if there is none.
pub fn resolve(problem: &Problem) -> Option<Resolution> {
    resolve_requirements(&problem.registry, &problem.root)
}

/// Like [`resolve`], with the root requirements given explicitly.
pub fn resolve_requirements(registry: &Registry, root: &[Requirement]) -> Option<Resolution> {
    let n = registry.package_count();
    let mut chosen: Vec<u32> = vec![UNSET; n];
    let mut trail: Vec<PackageId> = Vec::new();
    let mut arena: Vec<Node> = Vec::with_capacity(1024);
    let mut stack: Vec<Choice> = Vec::new();

    let mut pending = push_all(&mut arena, root, NIL);

    loop {
        // Consume the pending list until it is empty (success) or a
        // requirement cannot be met (fall through to backtracking).
        loop {
            if pending == NIL {
                return Some(finish(registry, &chosen));
            }
            let node = arena[pending as usize];
            let req = node.req;
            let rest = node.next;
            let c = chosen[req.package as usize];
            if c != UNSET {
                if req.admits(c) {
                    pending = rest;
                    continue;
                }
                break;
            }
            if req.lo >= req.hi {
                break;
            }
            let arena_len = arena.len() as u32;
            let trail_len = trail.len() as u32;
            // Take the first candidate right away; the choice point keeps the
            // remaining ones.
            let first = req.lo;
            chosen[req.package as usize] = first;
            trail.push(req.package);
            let reqs = registry.requirements(req.package, first);
            pending = push_all(&mut arena, reqs, rest);
            stack.push(Choice {
                package: req.package,
                next: first + 1,
                end: req.hi,
                rest,
                arena_len,
                trail_len,
            });
        }

        // Backtrack to the most recent choice point with an untried candidate.
        loop {
            let Some(cp) = stack.last_mut() else {
                return None;
            };
            while trail.len() as u32 > cp.trail_len {
                let p = trail.pop().unwrap();
                chosen[p as usize] = UNSET;
            }
            arena.truncate(cp.arena_len as usize);
            if cp.next < cp.end {
                let cand = cp.next;
                cp.next += 1;
                chosen[cp.package as usize] = cand;
                trail.push(cp.package);
                let reqs = registry.requirements(cp.package, cand);
                pending = push_all(&mut arena, reqs, cp.rest);
                break;
            }
            stack.pop();
        }
    }
}

/// Pushes `reqs` in front of the list `rest` (first requirement ends up at the
/// head) and returns the new head.
#[inline]
fn push_all(arena: &mut Vec<Node>, reqs: &[Requirement], rest: u32) -> u32 {
    let mut head = rest;
    for &req in reqs.iter().rev() {
        arena.push(Node { req, next: head });
        head = (arena.len() - 1) as u32;
    }
    head
}

fn finish(registry: &Registry, chosen: &[u32]) -> Resolution {
    let mut packages: Vec<(String, Version)> = chosen
        .iter()
        .enumerate()
        .filter(|&(_, &c)| c != UNSET)
        .map(|(id, &c)| {
            let id = id as PackageId;
            (registry.name(id).to_owned(), registry.versions(id)[c as usize])
        })
        .collect();
    packages.sort_unstable_by(|a, b| a.0.as_bytes().cmp(b.0.as_bytes()));
    Resolution { packages }
}
