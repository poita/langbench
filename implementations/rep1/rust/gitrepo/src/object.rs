//! Object types and parsers for commits, trees and tags.

use crate::error::{Error, Result};
use crate::oid::ObjectId;
use crate::sha1::hash_object;

/// The four kinds of git object.
#[derive(Clone, Copy, PartialEq, Eq, Debug, Hash)]
pub enum Kind {
    Commit,
    Tree,
    Blob,
    Tag,
}

impl Kind {
    /// The name used in object headers: `commit`, `tree`, `blob` or `tag`.
    pub fn name(self) -> &'static str {
        match self {
            Kind::Commit => "commit",
            Kind::Tree => "tree",
            Kind::Blob => "blob",
            Kind::Tag => "tag",
        }
    }

    /// Parses a header type name.
    pub fn from_name(name: &[u8]) -> Option<Kind> {
        match name {
            b"commit" => Some(Kind::Commit),
            b"tree" => Some(Kind::Tree),
            b"blob" => Some(Kind::Blob),
            b"tag" => Some(Kind::Tag),
            _ => None,
        }
    }
}

/// A raw, fully reconstructed object.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Object {
    pub kind: Kind,
    pub data: Vec<u8>,
}

impl Object {
    /// The id computed from the object's content (SHA-1 of its stored form).
    pub fn compute_id(&self) -> ObjectId {
        hash_object(self.kind.name(), &self.data)
    }
}

/// The name and timestamp taken from an `author` or `committer` line.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Ident {
    /// Everything before the first `<`, trailing whitespace removed.
    pub name: Vec<u8>,
    /// Seconds since the epoch; zero when absent.
    pub timestamp: u64,
}

fn is_space(b: u8) -> bool {
    matches!(b, b' ' | b'\t' | b'\r' | b'\n' | 0x0b | 0x0c)
}

fn trim_end(mut s: &[u8]) -> &[u8] {
    while let [rest @ .., last] = s {
        if is_space(*last) {
            s = rest;
        } else {
            break;
        }
    }
    s
}

impl Ident {
    /// Parses the value of an ident header (`Name <email> 123 +0000`).
    pub fn parse(line: &[u8]) -> Ident {
        let Some(lt) = line.iter().position(|&b| b == b'<') else {
            return Ident { name: trim_end(line).to_vec(), timestamp: 0 };
        };
        let name = trim_end(&line[..lt]).to_vec();
        let mut timestamp = 0u64;
        if let Some(gt) = line[lt..].iter().position(|&b| b == b'>') {
            let mut rest = &line[lt + gt + 1..];
            while let [b' ', tail @ ..] = rest {
                rest = tail;
            }
            if let [b'+' | b'-', tail @ ..] = rest {
                rest = tail;
            }
            for &d in rest.iter().take_while(|d| d.is_ascii_digit()) {
                timestamp = timestamp.saturating_mul(10).saturating_add((d - b'0') as u64);
            }
        }
        Ident { name, timestamp }
    }
}

/// Splits an object payload into its header lines and message.
///
/// Continuation lines (starting with a space) are dropped; every other
/// header is passed to `visit` as `(key, value)`. Returns the message.
fn parse_headers<'a>(data: &'a [u8], mut visit: impl FnMut(&'a [u8], &'a [u8]) -> Result<()>) -> Result<&'a [u8]> {
    let mut pos = 0;
    while pos < data.len() {
        let end = data[pos..].iter().position(|&b| b == b'\n').map_or(data.len(), |i| pos + i);
        let line = &data[pos..end];
        let next = (end + 1).min(data.len());
        if line.is_empty() {
            return Ok(&data[next..]);
        }
        pos = next;
        if line[0] == b' ' {
            continue;
        }
        match line.iter().position(|&b| b == b' ') {
            Some(sp) => visit(&line[..sp], &line[sp + 1..])?,
            None => visit(line, &[])?,
        }
    }
    Ok(&[])
}

/// A parsed commit.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Commit {
    /// The `tree` header (the last one wins); `None` if absent or malformed.
    pub tree: Option<ObjectId>,
    /// Every `parent` header, in order.
    pub parents: Vec<ObjectId>,
    pub author: Ident,
    pub committer: Ident,
    /// Everything after the first empty line.
    pub message: Vec<u8>,
}

impl Commit {
    /// Parses a commit payload. Fails only if a `parent` header is not a
    /// valid id.
    pub fn parse(data: &[u8]) -> Result<Commit> {
        let mut c = Commit::default();
        let message = parse_headers(data, |key, value| {
            match key {
                b"tree" => c.tree = ObjectId::from_hex(value),
                b"parent" => c.parents.push(
                    ObjectId::from_hex(value).ok_or_else(|| Error::corrupt("bad parent header"))?,
                ),
                b"author" => c.author = Ident::parse(value),
                b"committer" => c.committer = Ident::parse(value),
                _ => {}
            }
            Ok(())
        })?;
        c.message = message.to_vec();
        Ok(c)
    }

    /// The commit's subject line; see [`subject`].
    pub fn subject(&self) -> Vec<u8> {
        subject(&self.message)
    }
}

/// Computes the subject of a commit message: the first paragraph (lines
/// after leading blank lines, up to the next blank line) with trailing
/// whitespace stripped from each line and the lines joined by single spaces.
pub fn subject(message: &[u8]) -> Vec<u8> {
    let mut out = Vec::new();
    let mut started = false;
    for line in message.split(|&b| b == b'\n') {
        let line = trim_end(line);
        if line.is_empty() {
            if started {
                break;
            }
            continue;
        }
        if started {
            out.push(b' ');
        }
        started = true;
        out.extend_from_slice(line);
    }
    out
}

/// A parsed annotated tag.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Tag {
    /// The `object` header (the last one wins); `None` if absent or malformed.
    pub object: Option<ObjectId>,
}

impl Tag {
    /// Parses a tag payload. Only the `object` header is interpreted.
    pub fn parse(data: &[u8]) -> Tag {
        let mut t = Tag::default();
        let _ = parse_headers(data, |key, value| {
            if key == b"object" {
                t.object = ObjectId::from_hex(value);
            }
            Ok(())
        });
        t
    }
}

/// One entry of a tree.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TreeEntry {
    /// The stored mode, e.g. `0o100644`.
    pub mode: u32,
    pub name: Vec<u8>,
    pub id: ObjectId,
}

impl TreeEntry {
    /// The type of the object the entry names, decided by the mode's
    /// high bits: trees, submodule commits, and everything else is a blob.
    pub fn kind(&self) -> Kind {
        match self.mode & 0o170000 {
            0o040000 => Kind::Tree,
            0o160000 => Kind::Commit,
            _ => Kind::Blob,
        }
    }

    /// True if the entry is a subtree.
    pub fn is_tree(&self) -> bool {
        self.kind() == Kind::Tree
    }
}

/// Parses a tree payload into its entries, in stored order.
pub fn parse_tree(data: &[u8]) -> Result<Vec<TreeEntry>> {
    let mut entries = Vec::new();
    let mut pos = 0;
    while pos < data.len() {
        let sp = data[pos..]
            .iter()
            .position(|&b| b == b' ')
            .ok_or_else(|| Error::corrupt("tree entry without mode"))?;
        let mode_digits = &data[pos..pos + sp];
        if mode_digits.is_empty() || mode_digits.len() > 10 {
            return Err(Error::corrupt("bad tree entry mode"));
        }
        let mut mode = 0u32;
        for &d in mode_digits {
            if !(b'0'..=b'7').contains(&d) {
                return Err(Error::corrupt("bad tree entry mode"));
            }
            mode = mode.wrapping_mul(8).wrapping_add((d - b'0') as u32);
        }
        let name_start = pos + sp + 1;
        let nul = data[name_start..]
            .iter()
            .position(|&b| b == 0)
            .ok_or_else(|| Error::corrupt("tree entry without name terminator"))?;
        let name = data[name_start..name_start + nul].to_vec();
        let id_start = name_start + nul + 1;
        let id = data
            .get(id_start..id_start + 20)
            .and_then(ObjectId::from_slice)
            .ok_or_else(|| Error::corrupt("truncated tree entry id"))?;
        entries.push(TreeEntry { mode, name, id });
        pos = id_start + 20;
    }
    Ok(entries)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn subject_rules() {
        assert_eq!(subject(b"\n\nFix the thing   \nand the other\n\nbody\n"), b"Fix the thing and the other");
        assert_eq!(subject(b""), b"");
        assert_eq!(subject(b" \n\t\n"), b"");
        assert_eq!(subject(b"one\r\ntwo \x0b\n"), b"one two");
        assert_eq!(subject(b"  lead\n"), b"  lead");
    }

    #[test]
    fn ident_parsing() {
        let i = Ident::parse(b"Ada Lovelace  <ada@example.org> 1400003600 +0100");
        assert_eq!(i.name, b"Ada Lovelace");
        assert_eq!(i.timestamp, 1400003600);
        assert_eq!(Ident::parse(b"X <a>").timestamp, 0);
        assert_eq!(Ident::parse(b"X <a>   -77 +0000").timestamp, 77);
        assert_eq!(Ident::parse(b"X <a> abc").timestamp, 0);
        assert_eq!(Ident::parse(b"").name, b"");
        let odd = Ident::parse(b"> <a> 5");
        assert_eq!(odd.name, b">");
        assert_eq!(odd.timestamp, 5);
    }

    #[test]
    fn commit_headers() {
        let t1 = "1".repeat(40);
        let t2 = "2".repeat(40);
        let p = "3".repeat(40);
        let text = format!(
            "tree {t1}\ntree {t2}\nparent {p}\nauthor A <a> 10 +0000\ncommitter C <c> 20 +0000\ngpgsig -----BEGIN\n parent {t1}\n -----END\n\nmsg\n"
        );
        let c = Commit::parse(text.as_bytes()).unwrap();
        assert_eq!(c.tree, ObjectId::from_hex(t2.as_bytes()));
        assert_eq!(c.parents, vec![ObjectId::from_hex(p.as_bytes()).unwrap()]);
        assert_eq!(c.author.timestamp, 10);
        assert_eq!(c.committer.timestamp, 20);
        assert_eq!(c.message, b"msg\n");
        assert_eq!(c.subject(), b"msg");
    }

    #[test]
    fn commit_without_blank_line_has_empty_message() {
        let c = Commit::parse(b"author A <a> 1 +0000\n").unwrap();
        assert!(c.message.is_empty());
        assert!(Commit::parse(b"parent xyz\n\n").is_err());
    }

    #[test]
    fn tree_parsing() {
        let mut data = b"40000 dir\0".to_vec();
        data.extend_from_slice(&[1; 20]);
        data.extend_from_slice(b"100644 f.txt\0");
        data.extend_from_slice(&[2; 20]);
        let e = parse_tree(&data).unwrap();
        assert_eq!(e.len(), 2);
        assert_eq!(e[0].mode, 0o40000);
        assert!(e[0].is_tree());
        assert_eq!(e[1].name, b"f.txt");
        assert_eq!(e[1].kind(), Kind::Blob);
        assert!(parse_tree(&data[..data.len() - 1]).is_err());
        assert!(parse_tree(b"10x644 a\0").is_err());
    }

    #[test]
    fn tag_object() {
        let id = "a".repeat(40);
        let t = Tag::parse(format!("object {id}\ntype commit\ntag v1\n\nmsg").as_bytes());
        assert_eq!(t.object, ObjectId::from_hex(id.as_bytes()));
        assert_eq!(Tag::parse(b"tag v1\n").object, None);
    }
}
