//! The `.kiln-state` file: a strict reader, a canonical writer, and the
//! freshness decision.

use std::collections::BTreeMap;

use crate::hash::{hex, parse_hex};
use crate::step::Step;
use crate::workspace::{is_workspace_path, Workspace};

/// A `(path, hash)` record.
pub type PathHash = (String, u64);

/// What is remembered about one executed step.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Entry {
    /// The canonical command string.
    pub cmd: Vec<u8>,
    /// File inputs in declared order, with the hashes that were read.
    pub ins: Vec<PathHash>,
    /// Discovered dependencies, sorted by path.
    pub deps: Vec<PathHash>,
    /// The full output list in order, with the hashes that were written.
    pub outs: Vec<PathHash>,
}

/// The persisted build state, keyed by primary output path.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct State {
    entries: BTreeMap<String, Entry>,
}

impl State {
    /// An empty state.
    pub fn new() -> State {
        State::default()
    }

    /// The entry for the step whose primary output is `key`.
    pub fn get(&self, key: &str) -> Option<&Entry> {
        self.entries.get(key)
    }

    /// Adds or replaces an entry.
    pub fn insert(&mut self, key: String, e: Entry) {
        self.entries.insert(key, e);
    }

    /// Removes an entry, if present.
    pub fn remove(&mut self, key: &str) {
        self.entries.remove(key);
    }

    /// Number of entries.
    pub fn len(&self) -> usize {
        self.entries.len()
    }

    /// Whether there are no entries.
    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    /// Reads a state file. Any deviation from the grammar yields the empty
    /// state.
    ///
    /// ```
    /// use kiln::state::State;
    /// assert!(State::parse(b"kiln-state 1\n").is_empty());
    /// assert!(State::parse(b"garbage").is_empty());
    /// ```
    pub fn parse(data: &[u8]) -> State {
        parse_entries(data).unwrap_or_default()
    }

    /// Reads the state stored in the workspace's `.kiln-state`.
    pub fn load(ws: &Workspace) -> State {
        match ws.read(crate::workspace::STATE_PATH) {
            Some(d) => State::parse(d),
            None => State::new(),
        }
    }

    /// Renders the canonical state file.
    pub fn serialize(&self) -> Vec<u8> {
        let mut out = b"kiln-state 1\n".to_vec();
        for (key, e) in &self.entries {
            out.extend_from_slice(format!("step {key}\ncmd ").as_bytes());
            out.extend_from_slice(&e.cmd);
            out.push(b'\n');
            for (tag, list) in [("in", &e.ins), ("dep", &e.deps), ("out", &e.outs)] {
                for (p, h) in list {
                    out.extend_from_slice(format!("{tag} {p} {}\n", hex(*h)).as_bytes());
                }
            }
            out.extend_from_slice(b"end\n");
        }
        out
    }
}

fn path_hash(rest: &[u8]) -> Option<PathHash> {
    let mut it = rest.split(|&b| b == b' ');
    let (p, h) = (it.next()?, it.next()?);
    if it.next().is_some() || !is_workspace_path(p) {
        return None;
    }
    Some((String::from_utf8_lossy(p).into_owned(), parse_hex(h)?))
}

fn parse_entries(data: &[u8]) -> Option<State> {
    if data.last() != Some(&b'\n') {
        return None;
    }
    let lines: Vec<&[u8]> = data[..data.len() - 1].split(|&b| b == b'\n').collect();
    if lines[0] != b"kiln-state 1" {
        return None;
    }
    let mut state = State::new();
    let mut i = 1;
    while i < lines.len() {
        let key = lines[i].strip_prefix(b"step ")?;
        if !is_workspace_path(key) {
            return None;
        }
        let key = String::from_utf8_lossy(key).into_owned();
        i += 1;
        let cmd = lines.get(i)?.strip_prefix(b"cmd ")?;
        if cmd.is_empty() {
            return None;
        }
        i += 1;
        let mut sections: [Vec<PathHash>; 3] = Default::default();
        for (tag, section) in [&b"in "[..], b"dep ", b"out "].iter().zip(sections.iter_mut()) {
            while let Some(rest) = lines.get(i).and_then(|l| l.strip_prefix(*tag)) {
                section.push(path_hash(rest)?);
                i += 1;
            }
        }
        if lines.get(i) != Some(&&b"end"[..]) {
            return None;
        }
        i += 1;
        let [ins, deps, outs] = sections;
        if outs.first().map(|o| o.0.as_str()) != Some(key.as_str()) {
            return None;
        }
        let entry = Entry {
            cmd: cmd.to_vec(),
            ins,
            deps,
            outs,
        };
        if state.entries.insert(key, entry).is_some() {
            return None;
        }
    }
    Some(state)
}

/// Decides whether `step` is fresh (a cache hit) given its state entry and
/// the current workspace.
pub fn is_fresh(step: &Step, entry: Option<&Entry>, ws: &Workspace) -> bool {
    let Some(e) = entry else {
        return false;
    };
    if e.cmd != step.canonical {
        return false;
    }
    let same = |list: &[PathHash], paths: &[String]| {
        list.len() == paths.len() && list.iter().zip(paths).all(|(a, b)| a.0 == *b)
    };
    if !same(&e.outs, &step.full_outputs) || !same(&e.ins, &step.file_inputs) {
        return false;
    }
    e.ins
        .iter()
        .chain(&e.deps)
        .chain(&e.outs)
        .all(|(p, h)| ws.hash(p) == Some(*h))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample() -> Vec<u8> {
        b"kiln-state 1\nstep out/a\ncmd copy()\nin src/a 0123456789abcdef\ndep src/d 0123456789abcdef\nout out/a 0123456789abcdef\nend\n".to_vec()
    }

    #[test]
    fn roundtrip() {
        let s = State::parse(&sample());
        assert_eq!(s.len(), 1);
        assert_eq!(s.serialize(), sample());
    }

    #[test]
    fn rejects_malformed_files() {
        let good = String::from_utf8(sample()).unwrap();
        let bad = [
            good.trim_end().to_string(),
            good.replace("kiln-state 1", "kiln-state 2"),
            good.replace("0123456789abcdef", "0123456789ABCDEF"),
            good.replace("step out/a", "step out/b"),
            good.replace("cmd copy()", "cmd "),
            good.replace("in src/a", "in src/a x"),
            good.replace("dep src/d 0123456789abcdef\n", "") + "stray\n",
            good.replace("out out/a 0123456789abcdef\n", ""),
            good.replace("in src/a 0123456789abcdef\n", "") + &good[13..],
            good.replace("in src/a", "in bad path"),
            good.replacen("cmd copy()\n", "cmd copy()\ncmd copy()\n", 1),
            good.replace("end\n", ""),
        ];
        for b in bad {
            assert!(State::parse(b.as_bytes()).is_empty(), "{b:?}");
        }
    }

    #[test]
    fn unsorted_sections_are_accepted() {
        let t = "kiln-state 1\nstep out/a\ncmd x\ndep z 0123456789abcdef\ndep a 0123456789abcdef\ndep a 0123456789abcdef\nout out/a 0123456789abcdef\nend\nstep out/0\ncmd x\nout out/0 0123456789abcdef\nend\n";
        let s = State::parse(t.as_bytes());
        assert_eq!(s.len(), 2);
        assert!(s.serialize().starts_with(b"kiln-state 1\nstep out/0\n"));
    }
}
