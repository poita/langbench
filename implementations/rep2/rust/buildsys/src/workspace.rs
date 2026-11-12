//! The virtual file system: a flat map from workspace paths to contents.
//!
//! Every file carries a lazily computed, cached FNV-1a hash, so each distinct
//! content is hashed at most once however many builds consult it. Paths are
//! kept in a sorted map, which doubles as the index that makes `glob`
//! proportional to the paths sharing the pattern's literal prefix.

use std::cell::Cell;
use std::collections::BTreeMap;
use std::ops::Bound;
use std::fs;
use std::io;
use std::path::Path;
use std::rc::Rc;

use crate::glob::Pattern;
use crate::hash::fnv1a64;

/// The workspace path of the state file.
pub const STATE_PATH: &str = ".kiln-state";

/// Whether `b` is a valid workspace path (see the specification).
pub fn is_workspace_path(b: &[u8]) -> bool {
    if b.is_empty() || b.len() > 1024 {
        return false;
    }
    for comp in b.split(|&c| c == b'/') {
        if comp.is_empty() || comp.len() > 255 || comp == b"." || comp == b".." {
            return false;
        }
        if !comp
            .iter()
            .all(|&c| c.is_ascii_alphanumeric() || matches!(c, b'_' | b'.' | b'+' | b'-'))
        {
            return false;
        }
    }
    true
}

/// Whether the path's first component is exactly `out` (a generated path).
pub fn is_generated(path: &str) -> bool {
    path == "out" || path.starts_with("out/")
}

#[derive(Debug, Clone)]
struct File {
    data: Rc<Vec<u8>>,
    hash: Cell<Option<u64>>,
    stamp: u64,
}

/// A virtual file system holding the workspace of a session.
#[derive(Debug, Clone, Default)]
pub struct Workspace {
    files: BTreeMap<String, File>,
    clock: u64,
}

impl Workspace {
    /// Creates an empty workspace.
    pub fn new() -> Workspace {
        Workspace::default()
    }

    /// Creates or replaces the file at `path`.
    pub fn write(&mut self, path: &str, data: Vec<u8>) {
        self.clock += 1;
        self.files.insert(
            path.to_string(),
            File {
                data: Rc::new(data),
                hash: Cell::new(None),
                stamp: self.clock,
            },
        );
    }

    /// Removes the file at `path`; returns whether it existed.
    pub fn remove(&mut self, path: &str) -> bool {
        self.files.remove(path).is_some()
    }

    /// Updates the modification stamp of `path` (content is untouched).
    pub fn touch(&mut self, path: &str) {
        self.clock += 1;
        let clock = self.clock;
        if let Some(f) = self.files.get_mut(path) {
            f.stamp = clock;
        }
    }

    /// The modification stamp of `path`. Kiln itself never consults it.
    pub fn stamp(&self, path: &str) -> Option<u64> {
        self.files.get(path).map(|f| f.stamp)
    }

    /// Whether a file exists at `path`.
    pub fn contains(&self, path: &str) -> bool {
        self.files.contains_key(path)
    }

    /// The content of the file at `path`.
    pub fn read(&self, path: &str) -> Option<&[u8]> {
        self.files.get(path).map(|f| f.data.as_slice())
    }

    /// The content of the file at `path` as a cheaply clonable handle.
    pub fn read_shared(&self, path: &str) -> Option<Rc<Vec<u8>>> {
        self.files.get(path).map(|f| f.data.clone())
    }

    /// The FNV-1a hash of the file at `path`, computed once per content.
    pub fn hash(&self, path: &str) -> Option<u64> {
        let f = self.files.get(path)?;
        if let Some(h) = f.hash.get() {
            return Some(h);
        }
        let h = fnv1a64(&f.data);
        f.hash.set(Some(h));
        Some(h)
    }

    /// Number of files.
    pub fn len(&self) -> usize {
        self.files.len()
    }

    /// Whether the workspace holds no files.
    pub fn is_empty(&self) -> bool {
        self.files.is_empty()
    }

    /// All `(path, content)` pairs in ascending path order.
    pub fn iter(&self) -> impl Iterator<Item = (&str, &[u8])> {
        self.files
            .iter()
            .map(|(p, f)| (p.as_str(), f.data.as_slice()))
    }

    /// Every path whose first component is `out`, plus the state file, sorted.
    fn removable(&self) -> Vec<String> {
        self.files
            .keys()
            .filter(|p| is_generated(p) || p.as_str() == STATE_PATH)
            .cloned()
            .collect()
    }

    /// Implements the `clean` session step: deletes every generated path and
    /// the state file, returning the removed paths in ascending order.
    pub fn clean(&mut self) -> Vec<String> {
        let gone = self.removable();
        for p in &gone {
            self.files.remove(p);
        }
        gone
    }

    /// The sorted workspace paths matched by `pattern` that are eligible for
    /// `glob`: not generated and not the state file.
    ///
    /// Only the paths sharing the pattern's literal prefix are examined.
    pub fn glob(&self, pattern: &Pattern) -> Vec<&str> {
        let prefix = pattern.literal_prefix();
        let mut out = Vec::new();
        for (path, _) in self.files.range::<str, _>((Bound::Included(prefix), Bound::Unbounded)) {
            if !path.starts_with(prefix) {
                break;
            }
            if is_generated(path) || path == STATE_PATH {
                continue;
            }
            if pattern.is_match(path.as_bytes()) {
                out.push(path.as_str());
            }
        }
        out
    }

    /// Loads every regular file below `dir`, except the top-level
    /// `session.txt`, into a new workspace.
    pub fn load_dir(dir: &Path) -> io::Result<Workspace> {
        let mut ws = Workspace::new();
        load_rec(dir, "", &mut ws)?;
        Ok(ws)
    }

    /// Writes every file of the workspace below `dir`, creating directories.
    pub fn write_dir(&self, dir: &Path) -> io::Result<()> {
        for (path, data) in self.iter() {
            let target = dir.join(path);
            if let Some(parent) = target.parent() {
                fs::create_dir_all(parent)?;
            }
            fs::write(target, data)?;
        }
        Ok(())
    }
}

fn load_rec(dir: &Path, rel: &str, ws: &mut Workspace) -> io::Result<()> {
    for entry in fs::read_dir(dir)? {
        let entry = entry?;
        let name = entry.file_name().to_string_lossy().into_owned();
        let path = if rel.is_empty() {
            name.clone()
        } else {
            format!("{rel}/{name}")
        };
        let ty = entry.file_type()?;
        if ty.is_dir() {
            load_rec(&entry.path(), &path, ws)?;
        } else if ty.is_file() {
            if path == "session.txt" {
                continue;
            }
            ws.write(&path, fs::read(entry.path())?);
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn path_validation() {
        assert!(is_workspace_path(b"src/a.txt"));
        assert!(is_workspace_path(b"a+b-c_d.e"));
        assert!(!is_workspace_path(b""));
        assert!(!is_workspace_path(b"/a"));
        assert!(!is_workspace_path(b"a/"));
        assert!(!is_workspace_path(b"a//b"));
        assert!(!is_workspace_path(b"a/../b"));
        assert!(!is_workspace_path(b"./a"));
        assert!(!is_workspace_path(b"a b"));
        assert!(!is_workspace_path(b"a*"));
        assert!(!is_workspace_path("é".as_bytes()));
        assert!(!is_workspace_path(&vec![b'a'; 256]));
    }

    #[test]
    fn generated_paths() {
        assert!(is_generated("out"));
        assert!(is_generated("out/x"));
        assert!(!is_generated("outx/y"));
        assert!(!is_generated("src/out/x"));
    }

    #[test]
    fn hash_is_cached_and_reset_on_write() {
        let mut ws = Workspace::new();
        ws.write("a", b"hello\n".to_vec());
        assert_eq!(ws.hash("a"), Some(0xa9bc80cca21f28b3));
        ws.write("a", b"abc\n".to_vec());
        assert_eq!(ws.hash("a"), Some(0xfc17b183ee074373));
        assert_eq!(ws.hash("missing"), None);
    }

    #[test]
    fn clean_removes_out_and_state() {
        let mut ws = Workspace::new();
        for p in ["out/b", "out/a", ".kiln-state", "src/x", "outer"] {
            ws.write(p, vec![]);
        }
        assert_eq!(ws.clean(), vec![".kiln-state", "out/a", "out/b"]);
        assert_eq!(ws.len(), 2);
    }

    #[test]
    fn glob_skips_generated_and_state() {
        let mut ws = Workspace::new();
        for p in ["src/a.txt", "src/b.txt", "out/c.txt", ".kiln-state", "x.txt"] {
            ws.write(p, vec![]);
        }
        let pat = Pattern::compile(b"**/*.txt").unwrap();
        assert_eq!(ws.glob(&pat), vec!["src/a.txt", "src/b.txt", "x.txt"]);
        let pat = Pattern::compile(b"src/**").unwrap();
        assert_eq!(ws.glob(&pat), vec!["src/a.txt", "src/b.txt"]);
    }
}
