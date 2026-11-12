//! The line-oriented batch format used by the command-line tool.
//!
//! Input:
//!
//! ```text
//! N
//! pattern_1
//! M_1
//! subject_1_1
//! ...
//! ```
//!
//! For every subject one output line is written: `no`, or
//! `match <start> <end>` followed by `|<s>,<e>` (or `|-` when unset) for each
//! capture group.

use crate::{Error, Match, Regex};
use std::fmt;
use std::io::{self, Write};

/// Failure while processing a batch.
#[derive(Debug)]
pub enum BatchError {
    /// The input did not follow the format.
    Format(String),
    /// A pattern could not be compiled.
    Pattern {
        /// 1-based index of the pattern in the input.
        index: usize,
        /// The compile error.
        error: Error,
    },
    /// Writing the output failed.
    Io(io::Error),
}

impl fmt::Display for BatchError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            BatchError::Format(m) => write!(f, "malformed input: {m}"),
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

/// Splits input into lines on `\n`. A final line without a terminator is
/// still returned; an empty tail after the last `\n` is not a line.
struct Lines<'a> {
    rest: &'a [u8],
}

impl<'a> Iterator for Lines<'a> {
    type Item = &'a [u8];

    fn next(&mut self) -> Option<&'a [u8]> {
        if self.rest.is_empty() {
            return None;
        }
        match self.rest.iter().position(|&b| b == b'\n') {
            Some(i) => {
                let line = &self.rest[..i];
                self.rest = &self.rest[i + 1..];
                Some(line)
            }
            None => {
                let line = self.rest;
                self.rest = &[];
                Some(line)
            }
        }
    }
}

fn parse_count(line: &[u8], what: &str) -> Result<usize, BatchError> {
    std::str::from_utf8(line)
        .ok()
        .and_then(|s| s.trim().parse::<usize>().ok())
        .ok_or_else(|| BatchError::Format(format!("expected {what}")))
}

fn push_num(out: &mut Vec<u8>, mut n: usize) {
    let mut buf = [0u8; 20];
    let mut i = buf.len();
    loop {
        i -= 1;
        buf[i] = b'0' + (n % 10) as u8;
        n /= 10;
        if n == 0 {
            break;
        }
    }
    out.extend_from_slice(&buf[i..]);
}

/// Appends the output line (with trailing `\n`) for one search result.
pub fn format_result(out: &mut Vec<u8>, result: Option<&Match>) {
    match result {
        None => out.extend_from_slice(b"no\n"),
        Some(m) => {
            out.extend_from_slice(b"match ");
            push_num(out, m.start());
            out.push(b' ');
            push_num(out, m.end());
            for g in m.groups() {
                out.push(b'|');
                match g {
                    Some((s, e)) => {
                        push_num(out, *s);
                        out.push(b',');
                        push_num(out, *e);
                    }
                    None => out.push(b'-'),
                }
            }
            out.push(b'\n');
        }
    }
}

/// Processes a whole batch held in `input`, writing results to `out`.
pub fn process<W: Write>(input: &[u8], out: &mut W) -> Result<(), BatchError> {
    let mut lines = Lines { rest: input };
    let n = parse_count(
        lines
            .next()
            .ok_or_else(|| BatchError::Format("missing pattern count".into()))?,
        "pattern count",
    )?;
    let mut buf: Vec<u8> = Vec::with_capacity(1 << 17);
    for index in 1..=n {
        let pattern = lines
            .next()
            .ok_or_else(|| BatchError::Format(format!("missing pattern {index}")))?;
        let m = parse_count(
            lines
                .next()
                .ok_or_else(|| BatchError::Format(format!("missing subject count for pattern {index}")))?,
            "subject count",
        )?;
        let regex = Regex::from_bytes(pattern).map_err(|error| BatchError::Pattern { index, error })?;
        let mut matcher = regex.matcher();
        for _ in 0..m {
            let subject = lines
                .next()
                .ok_or_else(|| BatchError::Format(format!("missing subject for pattern {index}")))?;
            let result = matcher.find_bytes(subject);
            format_result(&mut buf, result.as_ref());
            if buf.len() >= 1 << 16 {
                out.write_all(&buf)?;
                buf.clear();
            }
        }
    }
    out.write_all(&buf)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn run(input: &str) -> String {
        let mut out = Vec::new();
        process(input.as_bytes(), &mut out).unwrap();
        String::from_utf8(out).unwrap()
    }

    #[test]
    fn spec_example_one() {
        let input = "3\n(a|ab)(c|bcd)(d*)\n1\nabcd\na*\n2\nbbb\n\n^(a+)+$\n2\naaaa\naaab\n";
        assert_eq!(
            run(input),
            "match 0 4|0,1|1,4|4,4\nmatch 0 0\nmatch 0 0\nmatch 0 4|0,4\nno\n"
        );
    }

    #[test]
    fn zero_subjects_produce_no_output() {
        assert_eq!(run("2\na\n0\nb\n1\nb\n"), "match 0 1\n");
    }

    #[test]
    fn whitespace_lines_are_verbatim() {
        // Pattern " " and subjects that are empty, a space, and look like numbers.
        assert_eq!(run("1\n \n3\n\n \n12\n"), "no\nmatch 0 1\nno\n");
    }

    #[test]
    fn missing_final_newline_is_tolerated() {
        assert_eq!(run("1\na\n1\na"), "match 0 1\n");
    }

    #[test]
    fn format_errors() {
        let mut out = Vec::new();
        assert!(matches!(process(b"", &mut out), Err(BatchError::Format(_))));
        assert!(matches!(process(b"1\na\n", &mut out), Err(BatchError::Format(_))));
        assert!(matches!(
            process(b"1\n(\n0\n", &mut out),
            Err(BatchError::Pattern { index: 1, .. })
        ));
    }
}
