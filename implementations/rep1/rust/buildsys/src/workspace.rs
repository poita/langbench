//! The virtual file system: a flat map from workspace paths to contents.
//!
//! Each file carries its FNV-1a hash (computed once, when the content is
//! stored) and a modification stamp that only `touch` updates.

use crate::glob::Pattern;
use crate::hash::fnv1a;
use std::collections::BTreeMap;
use std::io;
use std::ops::Bound;
use std::path::Path;
use std::rc::Rc;

/// The name of the persisted state file.
pub const STATE_FILE: &[u8] = b".kiln-state";

/// Whether `p` is a valid workspace path.
pub fn is_workspace_path(p: &[u8]) -> bool {
    if p.is_empty() || p.len() > 1024 {
        return false;
    }
    p.split(|&b| b == b'/').all(|c| {
        !c.is_empty()
            && c.len() <= 255
            && c != b"."
            && c != b".."
            && c.iter().all(|&b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'.' | b'+' | b'-'))
    })
}

/// Whether `s` matches `[A-Za-z_][A-Za-z0-9_]*`.
pub fn is_ident_shaped(s: &[u8]) -> bool {
    match s.split_first() {
        Some((&f, rest)) => {
            (f.is_ascii_alphabetic() || f == b'_') && rest.iter().all(|&b| b.is_ascii_alphanumeric() || b == b'_')
        }
        None => false,
    }
}

/// Whether the first component of `p` is exactly `out` (a generated path).
pub fn is_generated(p: &[u8]) -> bool {
    p == b"out" || p.starts_with(b"out/")
}

/// A stored file.
#[derive(Clone, Debug)]
pub struct File {
    pub content: Rc<Vec<u8>>,
    pub hash: u64,
    pub stamp: u64,
}

/// A map from workspace paths to files.
#[derive(Clone, Debug, Default)]
pub struct Workspace {
    files: BTreeMap<Vec<u8>, File>,
    tick: u64,
}

impl Workspace {
    /// An empty workspace.
    pub fn new() -> Workspace {
        Workspace::default()
    }

    /// Looks up a file.
    pub fn get(&self, path: &[u8]) -> Option<&File> {
        self.files.get(path)
    }

    /// Whether a file exists at `path`.
    pub fn contains(&self, path: &[u8]) -> bool {
        self.files.contains_key(path)
    }

    /// Writes (creating or replacing) a file.
    pub fn write(&mut self, path: &[u8], content: Vec<u8>) {
        let hash = fnv1a(&content);
        self.write_hashed(path, Rc::new(content), hash);
    }

    /// Writes a file whose hash is already known.
    pub fn write_hashed(&mut self, path: &[u8], content: Rc<Vec<u8>>, hash: u64) {
        self.tick += 1;
        self.files.insert(path.to_vec(), File { content, hash, stamp: self.tick });
    }

    /// Removes a file; returns whether it existed.
    pub fn remove(&mut self, path: &[u8]) -> bool {
        self.files.remove(path).is_some()
    }

    /// Updates a file's modification stamp (and nothing else).
    pub fn touch(&mut self, path: &[u8]) {
        self.tick += 1;
        let tick = self.tick;
        if let Some(f) = self.files.get_mut(path) {
            f.stamp = tick;
        }
    }

    /// All paths, in byte order.
    pub fn paths(&self) -> impl Iterator<Item = &Vec<u8>> {
        self.files.keys()
    }

    /// Number of files.
    pub fn len(&self) -> usize {
        self.files.len()
    }

    /// Whether the workspace has no files.
    pub fn is_empty(&self) -> bool {
        self.files.is_empty()
    }

    /// Removes every generated path and the state file; returns the removed
    /// paths in byte order.
    pub fn clean(&mut self) -> Vec<Vec<u8>> {
        let doomed: Vec<Vec<u8>> =
            self.files.keys().filter(|p| is_generated(p) || p.as_slice() == STATE_FILE).cloned().collect();
        for p in &doomed {
            self.files.remove(p);
        }
        doomed
    }

    /// The sorted paths matching `pattern`, excluding generated paths and
    /// the state file. Costs O(log F) plus the paths sharing the pattern's
    /// wildcard-free prefix.
    pub fn glob(&self, pattern: &Pattern) -> Vec<Vec<u8>> {
        let prefix = pattern.literal_prefix();
        let range = (Bound::Included(prefix), Bound::Unbounded);
        self.files
            .range::<[u8], _>(range)
            .take_while(|(p, _)| p.starts_with(prefix))
            .map(|(p, _)| p)
            .filter(|p| !is_generated(p) && p.as_slice() != STATE_FILE && pattern.matches(p))
            .cloned()
            .collect()
    }

    /// Loads a real directory tree. The top-level `session.txt` is skipped,
    /// as are files whose relative path is not a workspace path.
    pub fn load_dir(root: &Path) -> io::Result<Workspace> {
        let mut ws = Workspace::new();
        load_rec(root, &mut Vec::new(), &mut ws)?;
        Ok(ws)
    }

    /// Writes every file below `dir`, creating directories as needed.
    pub fn write_dir(&self, dir: &Path) -> io::Result<()> {
        std::fs::create_dir_all(dir)?;
        for (path, file) in &self.files {
            let rel = String::from_utf8_lossy(path).into_owned();
            let target = dir.join(rel);
            if let Some(parent) = target.parent() {
                std::fs::create_dir_all(parent)?;
            }
            std::fs::write(target, file.content.as_slice())?;
        }
        Ok(())
    }
}

fn load_rec(dir: &Path, rel: &mut Vec<u8>, ws: &mut Workspace) -> io::Result<()> {
    for entry in std::fs::read_dir(dir)? {
        let entry = entry?;
        let name = entry.file_name();
        let name_bytes = name.to_string_lossy().into_owned().into_bytes();
        let ty = entry.file_type()?;
        let saved = rel.len();
        if !rel.is_empty() {
            rel.push(b'/');
        }
        rel.extend_from_slice(&name_bytes);
        if ty.is_dir() {
            load_rec(&entry.path(), rel, ws)?;
        } else if ty.is_file() && rel.as_slice() != b"session.txt" && is_workspace_path(rel) {
            ws.write(rel, std::fs::read(entry.path())?);
        }
        rel.truncate(saved);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn path_validation() {
        for ok in ["a", "a/b.c", "src/x-y_z+1.txt", "out/.hidden"] {
            assert!(is_workspace_path(ok.as_bytes()), "{ok}");
        }
        for bad in ["", "/a", "a/", "a//b", ".", "..", "a/./b", "a/../b", "a b", "a*", "@x", "ü"] {
            assert!(!is_workspace_path(bad.as_bytes()), "{bad}");
        }
        assert!(!is_workspace_path("a".repeat(256).as_bytes()));
        assert!(is_workspace_path("a".repeat(255).as_bytes()));
    }

    #[test]
    fn generated_paths() {
        assert!(is_generated(b"out/x"));
        assert!(is_generated(b"out"));
        assert!(!is_generated(b"output/x"));
        assert!(!is_generated(b"src/out/x"));
    }

    #[test]
    fn glob_skips_out_and_state() {
        let mut ws = Workspace::new();
        for p in ["src/a.txt", "src/b.txt", "out/a.txt", ".kiln-state", "main.kiln"] {
            ws.write(p.as_bytes(), vec![]);
        }
        let pat = Pattern::compile(b"**").unwrap();
        let got = ws.glob(&pat);
        assert_eq!(got, vec![b"main.kiln".to_vec(), b"src/a.txt".to_vec(), b"src/b.txt".to_vec()]);
        let pat = Pattern::compile(b"src/**").unwrap();
        assert_eq!(ws.glob(&pat).len(), 2);
    }

    #[test]
    fn clean_removes_out_and_state() {
        let mut ws = Workspace::new();
        for p in ["src/a.txt", "out/a.txt", ".kiln-state"] {
            ws.write(p.as_bytes(), vec![1]);
        }
        let removed = ws.clean();
        assert_eq!(removed, vec![b".kiln-state".to_vec(), b"out/a.txt".to_vec()]);
        assert_eq!(ws.len(), 1);
    }
}
