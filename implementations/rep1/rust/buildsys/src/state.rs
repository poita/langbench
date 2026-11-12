//! The `.kiln-state` file: parsing, serialisation and freshness decisions.

use crate::hash::{hex, parse_hex};
use crate::step::Step;
use crate::workspace::{is_workspace_path, Workspace};
use std::collections::{BTreeMap, HashSet};

/// A path with the hash of the content that was read or written.
pub type Hashed = (Vec<u8>, u64);

/// What is remembered about one executed step.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Entry {
    pub cmd: Vec<u8>,
    pub ins: Vec<Hashed>,
    pub deps: Vec<Hashed>,
    pub outs: Vec<Hashed>,
}

/// All entries, keyed by primary output path.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct State {
    pub entries: BTreeMap<Vec<u8>, Entry>,
}

#[derive(PartialEq, Eq, Clone, Copy, PartialOrd, Ord)]
enum Section {
    Cmd,
    In,
    Dep,
    Out,
}

fn split_hashed(rest: &[u8]) -> Option<Hashed> {
    let mut it = rest.split(|&b| b == b' ');
    let (path, hash) = (it.next()?, it.next()?);
    if it.next().is_some() || !is_workspace_path(path) {
        return None;
    }
    Some((path.to_vec(), parse_hex(hash)?))
}

impl State {
    /// Parses a state file; any deviation from the grammar yields an empty
    /// state.
    pub fn parse(content: &[u8]) -> State {
        Self::try_parse(content).unwrap_or_default()
    }

    fn try_parse(content: &[u8]) -> Option<State> {
        if content.last() != Some(&b'\n') {
            return None;
        }
        let body = &content[..content.len() - 1];
        let mut lines = body.split(|&b| b == b'\n');
        if lines.next()? != b"kiln-state 1" {
            return None;
        }
        let mut state = State::default();
        let mut cur: Option<(Vec<u8>, Section, Entry)> = None;
        for line in lines {
            if line == b"end" {
                let (key, section, entry) = cur.take()?;
                if section != Section::Out || entry.outs.first()?.0 != key {
                    return None;
                }
                if state.entries.insert(key, entry).is_some() {
                    return None;
                }
                continue;
            }
            let sp = line.iter().position(|&b| b == b' ')?;
            let (key, rest) = (&line[..sp], &line[sp + 1..]);
            match key {
                b"step" => {
                    if cur.is_some() || !is_workspace_path(rest) {
                        return None;
                    }
                    // The entry starts before its `cmd` line.
                    let entry = Entry { cmd: Vec::new(), ins: vec![], deps: vec![], outs: vec![] };
                    cur = Some((rest.to_vec(), Section::Cmd, entry));
                }
                b"cmd" => {
                    let (_, section, entry) = cur.as_mut()?;
                    if *section != Section::Cmd || !entry.cmd.is_empty() || rest.is_empty() {
                        return None;
                    }
                    entry.cmd = rest.to_vec();
                    *section = Section::In;
                }
                b"in" | b"dep" | b"out" => {
                    let (_, section, entry) = cur.as_mut()?;
                    if *section == Section::Cmd {
                        return None;
                    }
                    let (want, list) = match key {
                        b"in" => (Section::In, &mut entry.ins),
                        b"dep" => (Section::Dep, &mut entry.deps),
                        _ => (Section::Out, &mut entry.outs),
                    };
                    if *section > want {
                        return None;
                    }
                    *section = want;
                    list.push(split_hashed(rest)?);
                }
                _ => return None,
            }
        }
        if cur.is_some() {
            return None;
        }
        Some(state)
    }

    /// The canonical serialisation.
    pub fn serialize(&self) -> Vec<u8> {
        let mut out = b"kiln-state 1\n".to_vec();
        for (key, e) in &self.entries {
            out.extend_from_slice(b"step ");
            out.extend_from_slice(key);
            out.extend_from_slice(b"\ncmd ");
            out.extend_from_slice(&e.cmd);
            out.push(b'\n');
            for (tag, list) in [("in", &e.ins), ("dep", &e.deps), ("out", &e.outs)] {
                for (path, h) in list {
                    out.extend_from_slice(tag.as_bytes());
                    out.push(b' ');
                    out.extend_from_slice(path);
                    out.push(b' ');
                    out.extend_from_slice(hex(*h).as_bytes());
                    out.push(b'\n');
                }
            }
            out.extend_from_slice(b"end\n");
        }
        out
    }

    /// Whether `step` is fresh: its recorded entry matches the command, the
    /// declared inputs and outputs, and every recorded file still has the
    /// recorded content.
    pub fn is_fresh(&self, step: &Step, ws: &Workspace) -> bool {
        let Some(e) = self.entries.get(step.primary()) else {
            return false;
        };
        if e.cmd != step.command_text
            || e.outs.len() != step.full_outputs.len()
            || e.ins.len() != step.file_inputs.len()
            || !e.outs.iter().zip(&step.full_outputs).all(|(a, b)| &a.0 == b)
            || !e.ins.iter().zip(&step.file_inputs).all(|(a, b)| &a.0 == b)
        {
            return false;
        }
        let mut checked: HashSet<&[u8]> = HashSet::new();
        e.ins.iter().chain(&e.deps).chain(&e.outs).all(|(path, hash)| {
            // Identical (path, hash) pairs need only be checked once.
            if !checked.insert(path.as_slice()) {
                return true;
            }
            ws.get(path).is_some_and(|f| f.hash == *hash)
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const GOOD: &str = "kiln-state 1\nstep out/a\ncmd write(\"x\")\nout out/a a9bc80cca21f28b3\nend\n";

    #[test]
    fn roundtrip() {
        let s = State::parse(GOOD.as_bytes());
        assert_eq!(s.entries.len(), 1);
        assert_eq!(s.serialize(), GOOD.as_bytes());
    }

    #[test]
    fn full_entry_roundtrip() {
        let text = "kiln-state 1\nstep out/b\ncmd preprocess()\nin src/m a9bc80cca21f28b3\nin src/m a9bc80cca21f28b3\ndep src/z a9bc80cca21f28b3\ndep src/d a9bc80cca21f28b3\nout out/b a9bc80cca21f28b3\nout out/b.d a9bc80cca21f28b3\nend\n";
        let s = State::parse(text.as_bytes());
        assert_eq!(s.serialize(), text.as_bytes());
    }

    #[test]
    fn rejects_corrupt_files() {
        let bad = [
            "",
            "kiln-state 2\n",
            "kiln-state 1",
            "kiln-state 1\nstep out/a\n",
            "kiln-state 1\nstep out/a\ncmd x\nend\n",
            "kiln-state 1\nstep out/a\nout out/a a9bc80cca21f28b3\nend\n",
            "kiln-state 1\nstep out/a\ncmd \nout out/a a9bc80cca21f28b3\nend\n",
            "kiln-state 1\nstep out/a\ncmd x\nout out/b a9bc80cca21f28b3\nend\n",
            "kiln-state 1\nstep out/a\ncmd x\nout out/a A9bc80cca21f28b3\nend\n",
            "kiln-state 1\nstep out/a\ncmd x\nout out/a a9bc80cca21f28b3 \nend\n",
            "kiln-state 1\nstep out/a\ncmd x\nout out/a a9bc80cca21f28b3\nin x a9bc80cca21f28b3\nend\n",
            "kiln-state 1\nstep out/a\ncmd x\nout out/a a9bc80cca21f28b3\nend \n",
            "kiln-state 1\nstep out/a\ncmd x\nout out/a a9bc80cca21f28b3\nend\nstray\n",
            "kiln-state 1\nstep ../a\ncmd x\nout ../a a9bc80cca21f28b3\nend\n",
        ];
        for b in bad {
            assert!(State::parse(b.as_bytes()).entries.is_empty(), "{b:?}");
        }
    }

    #[test]
    fn rejects_duplicate_keys() {
        let e = "step out/a\ncmd x\nout out/a a9bc80cca21f28b3\nend\n";
        let text = format!("kiln-state 1\n{e}{e}");
        assert!(State::parse(text.as_bytes()).entries.is_empty());
    }

    #[test]
    fn accepts_unsorted_entries_and_cmd_with_spaces() {
        let text = "kiln-state 1\nstep out/b\ncmd a b  c\nout out/b a9bc80cca21f28b3\nend\nstep out/a\ncmd x\nout out/a a9bc80cca21f28b3\nend\n";
        let s = State::parse(text.as_bytes());
        assert_eq!(s.entries.len(), 2);
        assert!(s.serialize().starts_with(b"kiln-state 1\nstep out/a\n"));
    }
}
