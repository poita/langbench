//! The six queries, plus the line parser that dispatches them.
//!
//! Every function returns the exact bytes the command prints. The caller
//! decides what to do with an `Err`; the command-line tool prints `error`.

use std::cmp::Reverse;
use std::collections::{BinaryHeap, HashSet};

use crate::error::{Error, Result};
use crate::object::{Kind, TreeEntry};
use crate::oid::ObjectId;
use crate::quote::quote_path;
use crate::repo::Repository;
use crate::rev::{peel_object, resolve, Peel};

/// Runs one command line (without its line terminator) against a repository.
///
/// The line is split on single spaces; an empty token, an unknown command or
/// the wrong number of arguments is an error.
pub fn execute(repo: &Repository, line: &[u8]) -> Result<Vec<u8>> {
    let tokens: Vec<&[u8]> = line.split(|&b| b == b' ').collect();
    if tokens.iter().any(|t| t.is_empty()) {
        return Err(Error::invalid("empty token"));
    }
    match (tokens[0], &tokens[1..]) {
        (b"log", [rev]) => log(repo, rev, None),
        (b"log", [rev, n]) => log(repo, rev, Some(n)),
        (b"ls-tree", [rev]) => ls_tree(repo, rev, None),
        (b"ls-tree", [rev, path]) => ls_tree(repo, rev, Some(path)),
        (b"cat-file", [rev]) => cat_file(repo, rev),
        (b"diff", [a, b]) => diff(repo, a, b),
        (b"rev-parse", [rev]) => rev_parse(repo, rev),
        (b"count-objects", []) => Ok(count_objects(repo)),
        _ => Err(Error::invalid("unknown command or wrong argument count")),
    }
}

fn peeled(repo: &Repository, rev: &[u8], kind: Kind) -> Result<ObjectId> {
    let id = resolve(repo, rev)?;
    peel_object(repo, id, Peel::To(kind))
}

/// `log <rev> [<n>]`: commits reachable from `rev` in reverse chronological
/// order of committer date (ties: discovery order), one line each:
/// `<id> <author name> <author time> <subject>`. `limit` is the optional
/// count as typed (a run of decimal digits).
pub fn log(repo: &Repository, rev: &[u8], limit: Option<&[u8]>) -> Result<Vec<u8>> {
    let limit = match limit {
        None => u64::MAX,
        Some(n) if !n.is_empty() && n.iter().all(u8::is_ascii_digit) => n
            .iter()
            .fold(0u64, |a, &d| a.saturating_mul(10).saturating_add((d - b'0') as u64)),
        Some(_) => return Err(Error::invalid("bad log count")),
    };
    let start = peeled(repo, rev, Kind::Commit)?;
    let mut out = Vec::new();
    // Max-heap on (date, Reverse(discovery order)).
    let mut heap = BinaryHeap::new();
    let mut seen = HashSet::new();
    let mut seq = 0u64;
    heap.push((repo.commit(&start)?.committer.timestamp, Reverse(seq), start));
    seen.insert(start);
    let mut emitted = 0u64;
    while emitted < limit {
        let Some((_, _, id)) = heap.pop() else { break };
        let commit = repo.commit(&id)?;
        out.extend_from_slice(id.to_hex().as_bytes());
        out.push(b' ');
        out.extend_from_slice(&commit.author.name);
        out.push(b' ');
        out.extend_from_slice(commit.author.timestamp.to_string().as_bytes());
        out.push(b' ');
        out.extend_from_slice(&commit.subject());
        out.push(b'\n');
        emitted += 1;
        if emitted == limit {
            break;
        }
        for &p in &commit.parents {
            if seen.insert(p) {
                seq += 1;
                heap.push((repo.commit(&p)?.committer.timestamp, Reverse(seq), p));
            }
        }
    }
    Ok(out)
}

/// `ls-tree <rev> [<path>]`: the entries of a tree, in stored order.
pub fn ls_tree(repo: &Repository, rev: &[u8], path: Option<&[u8]>) -> Result<Vec<u8>> {
    let mut tree = peeled(repo, rev, Kind::Tree)?;
    if let Some(path) = path {
        for component in path.split(|&b| b == b'/') {
            if component.is_empty() || component == b"." || component == b".." {
                return Err(Error::invalid("bad path"));
            }
        }
        for component in path.split(|&b| b == b'/') {
            let entries = repo.tree(&tree)?;
            let entry = entries
                .iter()
                .find(|e| e.name == component)
                .filter(|e| e.is_tree())
                .ok_or_else(|| Error::not_found("path component is not a tree"))?;
            tree = entry.id;
        }
    }
    let mut out = Vec::new();
    for e in repo.tree(&tree)?.iter() {
        out.extend_from_slice(
            format!("{:06o} {} {}\t", e.mode, e.kind().name(), e.id).as_bytes(),
        );
        out.extend_from_slice(&quote_path(&e.name));
        out.push(b'\n');
    }
    Ok(out)
}

/// `cat-file <rev>`: `<type> <size>\n` followed by the verified payload.
pub fn cat_file(repo: &Repository, rev: &[u8]) -> Result<Vec<u8>> {
    let id = resolve(repo, rev)?;
    let object = repo.read_verified(&id)?;
    let mut out = format!("{} {}\n", object.kind.name(), object.data.len()).into_bytes();
    out.extend_from_slice(&object.data);
    Ok(out)
}

/// `rev-parse <rev>`: the id a revision resolves to.
pub fn rev_parse(repo: &Repository, rev: &[u8]) -> Result<Vec<u8>> {
    let mut out = resolve(repo, rev)?.to_hex().into_bytes();
    out.push(b'\n');
    Ok(out)
}

/// `count-objects`: loose files, objects in packs, and packs.
pub fn count_objects(repo: &Repository) -> Vec<u8> {
    let s = repo.store();
    format!(
        "loose: {}\nin-pack: {}\npacks: {}\n",
        s.loose_count(),
        s.packed_object_count(),
        s.pack_count()
    )
    .into_bytes()
}

/// A flattened tree: every non-tree entry under its full path.
type Flat = Vec<(Vec<u8>, u32, ObjectId)>;

fn flatten(repo: &Repository, tree: &ObjectId, prefix: &mut Vec<u8>, out: &mut Flat) -> Result<()> {
    let entries = repo.tree(tree)?;
    for e in entries.iter() {
        let TreeEntry { mode, name, id } = e;
        let keep = prefix.len();
        prefix.extend_from_slice(name);
        if e.is_tree() {
            prefix.push(b'/');
            flatten(repo, id, prefix, out)?;
        } else {
            out.push((prefix.clone(), *mode, *id));
        }
        prefix.truncate(keep);
    }
    Ok(())
}

/// `diff <rev1> <rev2>`: raw recursive tree diff, sorted by path.
pub fn diff(repo: &Repository, rev1: &[u8], rev2: &[u8]) -> Result<Vec<u8>> {
    let t1 = peeled(repo, rev1, Kind::Tree)?;
    let t2 = peeled(repo, rev2, Kind::Tree)?;
    let (mut a, mut b) = (Flat::new(), Flat::new());
    flatten(repo, &t1, &mut Vec::new(), &mut a)?;
    flatten(repo, &t2, &mut Vec::new(), &mut b)?;
    a.sort_by(|x, y| x.0.cmp(&y.0));
    b.sort_by(|x, y| x.0.cmp(&y.0));
    let mut out = Vec::new();
    let mut emit = |path: &[u8], old: Option<(u32, ObjectId)>, new: Option<(u32, ObjectId)>| {
        let (m1, i1) = old.unwrap_or((0, ObjectId::ZERO));
        let (m2, i2) = new.unwrap_or((0, ObjectId::ZERO));
        let status = match (old, new) {
            (None, _) => 'A',
            (_, None) => 'D',
            _ if m1 & 0o170000 == m2 & 0o170000 => 'M',
            _ => 'T',
        };
        out.extend_from_slice(format!(":{m1:06o} {m2:06o} {i1} {i2} {status}\t").as_bytes());
        out.extend_from_slice(&quote_path(path));
        out.push(b'\n');
    };
    let (mut i, mut j) = (0, 0);
    while i < a.len() || j < b.len() {
        let order = match (a.get(i), b.get(j)) {
            (Some(x), Some(y)) => x.0.cmp(&y.0),
            (Some(_), None) => std::cmp::Ordering::Less,
            _ => std::cmp::Ordering::Greater,
        };
        match order {
            std::cmp::Ordering::Less => {
                emit(&a[i].0, Some((a[i].1, a[i].2)), None);
                i += 1;
            }
            std::cmp::Ordering::Greater => {
                emit(&b[j].0, None, Some((b[j].1, b[j].2)));
                j += 1;
            }
            std::cmp::Ordering::Equal => {
                if (a[i].1, a[i].2) != (b[j].1, b[j].2) {
                    emit(&a[i].0, Some((a[i].1, a[i].2)), Some((b[j].1, b[j].2)));
                }
                i += 1;
                j += 1;
            }
        }
    }
    Ok(out)
}
