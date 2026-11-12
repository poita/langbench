//! Reading mailboxes: mbox files and directories of `.eml` files.

use std::fs;
use std::io;
use std::path::Path;

use crate::lines::Lines;

/// One message as extracted from a mailbox.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RawMessage {
    /// `mbox:<n>` for mbox input, the file name for directory input.
    pub source: String,
    /// The message bytes.
    pub data: Vec<u8>,
}

/// Splits an mbox archive into messages.
///
/// A separator is a line starting with `From ` that is the first line of the
/// file or follows an empty line. Text before the first separator is dropped,
/// and a message ending in two LFs loses the last one.
pub fn split_mbox(data: &[u8]) -> Vec<&[u8]> {
    // (offset after the separator line, offset where the separator line starts)
    let mut seps: Vec<(usize, usize)> = Vec::new();
    let mut prev_empty = true; // the first line counts as preceded by an empty line
    for line in Lines::crlf(data) {
        if prev_empty && data[line.start..line.end].starts_with(b"From ") {
            seps.push((line.next, line.start));
        }
        prev_empty = line.is_empty();
    }
    let mut out = Vec::with_capacity(seps.len());
    for (k, &(body_start, _)) in seps.iter().enumerate() {
        let end = seps.get(k + 1).map_or(data.len(), |&(_, s)| s);
        let mut msg = &data[body_start..end];
        if msg.ends_with(b"\n\n") {
            msg = &msg[..msg.len() - 1];
        }
        out.push(msg);
    }
    out
}

#[cfg(unix)]
fn name_bytes(name: &std::ffi::OsStr) -> Vec<u8> {
    use std::os::unix::ffi::OsStrExt;
    name.as_bytes().to_vec()
}

#[cfg(not(unix))]
fn name_bytes(name: &std::ffi::OsStr) -> Vec<u8> {
    name.to_string_lossy().into_owned().into_bytes()
}

/// Reads the messages of the mailbox at `path`: a regular file is an mbox,
/// a directory holds one message per `.eml` file (in byte order of names).
pub fn read_mailbox(path: &Path) -> io::Result<Vec<RawMessage>> {
    if fs::metadata(path)?.is_dir() {
        let mut files: Vec<(Vec<u8>, std::path::PathBuf)> = Vec::new();
        for entry in fs::read_dir(path)? {
            let entry = entry?;
            let bytes = name_bytes(&entry.file_name());
            if bytes.ends_with(b".eml") && fs::metadata(entry.path())?.is_file() {
                files.push((bytes, entry.path()));
            }
        }
        files.sort();
        let mut out = Vec::with_capacity(files.len());
        for (name, p) in files {
            out.push(RawMessage {
                source: String::from_utf8_lossy(&name).into_owned(),
                data: fs::read(p)?,
            });
        }
        Ok(out)
    } else {
        let data = fs::read(path)?;
        Ok(split_mbox(&data)
            .into_iter()
            .enumerate()
            .map(|(i, m)| RawMessage { source: format!("mbox:{}", i + 1), data: m.to_vec() })
            .collect())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn splits_on_separator_after_blank_line() {
        let data = b"junk\n\nFrom x\nA: 1\n\nbody\n\nFrom y\nB: 2\n\n";
        let msgs = split_mbox(data);
        assert_eq!(msgs, vec![&b"A: 1\n\nbody\n"[..], b"B: 2\n"]);
    }

    #[test]
    fn from_line_without_blank_is_body() {
        let data = b"From x\nA: 1\n\nFrom not a separator\nmore";
        let msgs = split_mbox(data);
        assert_eq!(msgs.len(), 2);
        let data = b"From x\nA: 1\nFrom y\nmore";
        assert_eq!(split_mbox(data), vec![&b"A: 1\nFrom y\nmore"[..]]);
    }

    #[test]
    fn no_separator_no_messages() {
        assert!(split_mbox(b"Subject: x\n\nbody\n").is_empty());
        assert!(split_mbox(b"").is_empty());
    }

    #[test]
    fn trailing_lf_rule() {
        assert_eq!(split_mbox(b"From x\na\n\n\n"), vec![&b"a\n\n"[..]]);
        assert_eq!(split_mbox(b"From x\na\n"), vec![&b"a\n"[..]]);
        assert_eq!(split_mbox(b"From x"), vec![&b""[..]]);
    }
}
