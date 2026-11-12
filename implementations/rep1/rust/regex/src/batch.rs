//! The batch input/output format: many patterns, each followed by subjects.
//!
//! Input is `N`, then for each pattern a pattern line, a count `M` and `M`
//! subject lines, all `\n`-terminated and taken verbatim. Output is one line
//! per subject: `no`, or `match <start> <end>` followed by `|<gs>,<ge>` or
//! `|-` for every group.

use crate::{Regex, Scratch};
use std::fmt;
use std::io::{self, Write};

/// An error while processing a batch.
#[derive(Debug)]
pub enum BatchError {
    /// The input does not follow the format.
    Malformed(String),
    /// A pattern failed to compile.
    Pattern {
        /// 1-based index of the pattern.
        index: usize,
        /// The underlying error.
        error: crate::Error,
    },
    /// Writing the output failed.
    Io(io::Error),
}

impl fmt::Display for BatchError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            BatchError::Malformed(m) => write!(f, "malformed input: {m}"),
            BatchError::Pattern { index, error } => write!(f, "pattern {index}: {error}"),
            BatchError::Io(e) => write!(f, "I/O error: {e}"),
        }
    }
}

impl std::error::Error for BatchError {}

impl From<io::Error> for BatchError {
    fn from(e: io::Error) -> Self {
        BatchError::Io(e)
    }
}

struct Lines<'a> {
    data: &'a [u8],
    pos: usize,
}

impl<'a> Lines<'a> {
    /// The next line without its `\n`; a final unterminated line is accepted.
    fn next_line(&mut self) -> Option<&'a [u8]> {
        if self.pos >= self.data.len() {
            return None;
        }
        let rest = &self.data[self.pos..];
        match rest.iter().position(|&b| b == b'\n') {
            Some(i) => {
                self.pos += i + 1;
                Some(&rest[..i])
            }
            None => {
                self.pos = self.data.len();
                Some(rest)
            }
        }
    }

    fn require(&mut self, what: &str) -> Result<&'a [u8], BatchError> {
        self.next_line()
            .ok_or_else(|| BatchError::Malformed(format!("unexpected end of input, expected {what}")))
    }

    fn number(&mut self, what: &str) -> Result<usize, BatchError> {
        let line = self.require(what)?;
        if line.is_empty() || !line.iter().all(u8::is_ascii_digit) || line.len() > 18 {
            return Err(BatchError::Malformed(format!("expected {what}, found {:?}", String::from_utf8_lossy(line))));
        }
        Ok(line.iter().fold(0usize, |a, &d| a * 10 + (d - b'0') as usize))
    }
}

fn push_num(buf: &mut Vec<u8>, mut n: usize) {
    let mut tmp = [0u8; 20];
    let mut i = tmp.len();
    loop {
        i -= 1;
        tmp[i] = b'0' + (n % 10) as u8;
        n /= 10;
        if n == 0 {
            break;
        }
    }
    buf.extend_from_slice(&tmp[i..]);
}

/// Appends the output line for one search result to `buf`.
pub fn format_result(buf: &mut Vec<u8>, matched: bool, scratch: &Scratch) {
    if !matched {
        buf.extend_from_slice(b"no\n");
        return;
    }
    buf.extend_from_slice(b"match ");
    push_num(buf, scratch.start());
    buf.push(b' ');
    push_num(buf, scratch.end());
    for g in 1..=scratch.group_count() {
        buf.push(b'|');
        match scratch.group(g) {
            Some((s, e)) => {
                push_num(buf, s);
                buf.push(b',');
                push_num(buf, e);
            }
            None => buf.push(b'-'),
        }
    }
    buf.push(b'\n');
}

/// Processes a whole batch `input`, writing results to `out`.
pub fn run<W: Write>(input: &[u8], out: &mut W) -> Result<(), BatchError> {
    const FLUSH_AT: usize = 1 << 20;
    let mut lines = Lines { data: input, pos: 0 };
    let n = lines.number("pattern count")?;
    let mut buf: Vec<u8> = Vec::with_capacity(FLUSH_AT + 4096);
    let mut scratch = Scratch::new();
    for index in 1..=n {
        let pattern = lines.require("pattern")?;
        let m = lines.number("subject count")?;
        let re = Regex::from_bytes(pattern).map_err(|error| BatchError::Pattern { index, error })?;
        for _ in 0..m {
            let subject = lines.require("subject")?;
            let matched = re.search(subject, &mut scratch);
            format_result(&mut buf, matched, &scratch);
            if buf.len() >= FLUSH_AT {
                out.write_all(&buf)?;
                buf.clear();
            }
        }
    }
    out.write_all(&buf)?;
    out.flush()?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn go(input: &str) -> String {
        let mut out = Vec::new();
        run(input.as_bytes(), &mut out).unwrap();
        String::from_utf8(out).unwrap()
    }

    #[test]
    fn positional_format_with_odd_lines() {
        // Empty pattern, subject that looks like a number, zero subjects.
        let out = go("3\n\n2\n\n5\nx\n0\n a \n1\nb a c\n");
        assert_eq!(out, "match 0 0\nmatch 0 0\nmatch 1 4\n");
    }

    #[test]
    fn missing_input_is_an_error() {
        let mut out = Vec::new();
        assert!(run(b"1\na\n2\nb\n", &mut out).is_err());
        assert!(run(b"x\n", &mut out).is_err());
    }
}
