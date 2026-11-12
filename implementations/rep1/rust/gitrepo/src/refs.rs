//! Refs: `HEAD`, loose files under `refs/` and `packed-refs`.

use std::collections::HashMap;
use std::ffi::OsStr;
use std::fs;
use std::os::unix::ffi::OsStrExt;
use std::path::{Path, PathBuf};

use crate::oid::ObjectId;

/// How many symbolic refs may be followed in a row.
const MAX_SYMREF_DEPTH: u32 = 5;

/// Access to a repository's refs.
pub struct Refs {
    root: PathBuf,
    packed: HashMap<Vec<u8>, ObjectId>,
}

/// True for `HEAD` and for names under `refs/`, with no empty, `.` or `..`
/// component.
fn is_ref_name(name: &[u8]) -> bool {
    if name != b"HEAD" && !name.starts_with(b"refs/") {
        return false;
    }
    name.split(|&b| b == b'/').all(|c| !c.is_empty() && c != b"." && c != b"..")
}

fn trim_end(mut s: &[u8]) -> &[u8] {
    while let [rest @ .., last] = s {
        if last.is_ascii_whitespace() || *last == 0x0b {
            s = rest;
        } else {
            break;
        }
    }
    s
}

impl Refs {
    /// Reads `packed-refs` (if any) from the repository directory.
    pub fn open(root: &Path) -> Refs {
        let mut packed = HashMap::new();
        if let Ok(text) = fs::read(root.join("packed-refs")) {
            for line in text.split(|&b| b == b'\n') {
                if line.is_empty() || line[0] == b'#' || line[0] == b'^' {
                    continue;
                }
                if line.len() > 41 && line[40] == b' ' {
                    if let Some(id) = ObjectId::from_hex(&line[..40]) {
                        packed.entry(line[41..].to_vec()).or_insert(id);
                    }
                }
            }
        }
        Refs { root: root.to_path_buf(), packed }
    }

    /// Resolves a full ref name (`HEAD`, `refs/heads/main`, ...) to the id it
    /// holds. The object need not exist.
    pub fn resolve(&self, name: &[u8]) -> Option<ObjectId> {
        self.resolve_depth(name, 0)
    }

    fn resolve_depth(&self, name: &[u8], follows: u32) -> Option<ObjectId> {
        if !is_ref_name(name) {
            return None;
        }
        let path = self.root.join(OsStr::from_bytes(name));
        let Ok(content) = fs::read(path) else {
            return self.packed.get(name).copied();
        };
        let content = trim_end(&content);
        if let Some(target) = content.strip_prefix(b"ref: ") {
            if follows >= MAX_SYMREF_DEPTH {
                return None;
            }
            return self.resolve_depth(target, follows + 1);
        }
        ObjectId::from_hex(content)
    }
}
