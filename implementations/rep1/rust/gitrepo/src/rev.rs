//! Revision syntax: names, abbreviated ids, `^`, `~` and `^{...}`.

use crate::error::{Error, Result};
use crate::object::{Kind, Tag};
use crate::oid::ObjectId;
use crate::repo::Repository;

/// What a `^{...}` suffix asks for.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Peel {
    /// `^{}`: strip tags only.
    Tags,
    /// `^{commit}`, `^{tree}`, `^{blob}`, `^{tag}`.
    To(Kind),
    /// `^{object}`: no change, but the object must be present.
    Present,
}

/// Resolves a revision string to an object id.
///
/// This implements, in order: `^{...}` peels, `^n` / `~n` suffixes, ref
/// names tried against the six standard patterns, and finally 4–40 digit
/// (abbreviated) hexadecimal ids. Only the final hexadecimal rule and
/// `^{object}` check that an object exists.
pub fn resolve(repo: &Repository, rev: &[u8]) -> Result<ObjectId> {
    // Rule 1: `<rev>^{<peel>}`.
    if rev.last() == Some(&b'}') {
        if let Some(pos) = rev.windows(2).rposition(|w| w == b"^{") {
            if pos != 0 {
                let base = resolve(repo, &rev[..pos])?;
                let inner = &rev[pos + 2..rev.len() - 1];
                let peel = match inner {
                    b"" => Peel::Tags,
                    b"commit" => Peel::To(Kind::Commit),
                    b"tree" => Peel::To(Kind::Tree),
                    b"blob" => Peel::To(Kind::Blob),
                    b"tag" => Peel::To(Kind::Tag),
                    b"object" => Peel::Present,
                    _ => return Err(Error::invalid("unknown peel type")),
                };
                return peel_object(repo, base, peel);
            }
        }
    }
    // Rule 2: `<rev>^n` and `<rev>~n`.
    let digits = rev.iter().rev().take_while(|b| b.is_ascii_digit()).count();
    let op_pos = rev.len() - digits;
    if op_pos > 0 && matches!(rev[op_pos - 1], b'^' | b'~') {
        let op = rev[op_pos - 1];
        let n = if digits == 0 {
            1
        } else {
            rev[op_pos..]
                .iter()
                .fold(0u64, |acc, &d| acc.saturating_mul(10).saturating_add((d - b'0') as u64))
        };
        let base = resolve(repo, &rev[..op_pos - 1])?;
        let mut id = peel_object(repo, base, Peel::To(Kind::Commit))?;
        if op == b'^' {
            if n == 0 {
                return Ok(id);
            }
            let commit = repo.commit(&id)?;
            return commit
                .parents
                .get((n - 1).min(usize::MAX as u64) as usize)
                .copied()
                .ok_or_else(|| Error::invalid("commit has too few parents"));
        }
        for _ in 0..n {
            let commit = repo.commit(&id)?;
            id = *commit.parents.first().ok_or_else(|| Error::invalid("no parent to follow"))?;
        }
        return Ok(id);
    }
    // Rule 3: ref names.
    if let Some(id) = resolve_name(repo, rev) {
        return Ok(id);
    }
    // Rule 4: object ids.
    if (4..=40).contains(&rev.len()) && rev.iter().all(u8::is_ascii_hexdigit) {
        let hex = rev.to_ascii_lowercase();
        if hex.len() == 40 {
            let id = ObjectId::from_hex(&hex).expect("40 hex digits");
            if repo.store().contains(&id) {
                return Ok(id);
            }
        } else if let Some(id) = repo.store().find_by_prefix(&hex) {
            return Ok(id);
        }
    }
    Err(Error::invalid("revision does not resolve"))
}

fn resolve_name(repo: &Repository, name: &[u8]) -> Option<ObjectId> {
    let candidates: [Vec<u8>; 6] = [
        name.to_vec(),
        [b"refs/", name].concat(),
        [b"refs/tags/", name].concat(),
        [b"refs/heads/", name].concat(),
        [b"refs/remotes/", name].concat(),
        [b"refs/remotes/", name, b"/HEAD"].concat(),
    ];
    candidates.iter().find_map(|c| repo.refs().resolve(c))
}

/// Applies a peel to an object id, reading objects as needed.
pub fn peel_object(repo: &Repository, id: ObjectId, peel: Peel) -> Result<ObjectId> {
    let mut id = id;
    match peel {
        Peel::Present => {
            if repo.store().contains(&id) {
                Ok(id)
            } else {
                Err(Error::not_found(format!("object {id}")))
            }
        }
        Peel::Tags => loop {
            let object = repo.read_object(&id)?;
            if object.kind != Kind::Tag {
                return Ok(id);
            }
            id = tag_target(&object.data)?;
        },
        Peel::To(want) => loop {
            let object = repo.read_object(&id)?;
            if object.kind == want {
                return Ok(id);
            }
            match object.kind {
                Kind::Tag => id = tag_target(&object.data)?,
                Kind::Commit => {
                    id = repo
                        .commit(&id)?
                        .tree
                        .ok_or_else(|| Error::corrupt("commit without tree"))?
                }
                _ => return Err(Error::invalid("cannot peel to requested type")),
            }
        },
    }
}

fn tag_target(data: &[u8]) -> Result<ObjectId> {
    Tag::parse(data).object.ok_or_else(|| Error::corrupt("tag without object"))
}
