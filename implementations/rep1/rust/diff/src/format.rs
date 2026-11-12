//! The textual request/response format used by the command-line tool.
//!
//! A request is the mode line (`diff` or `patch`), then two counted blocks of
//! lines. Lines are taken verbatim between `\n` bytes and are never trimmed;
//! they are handled as raw bytes, so no UTF-8 decoding is needed. See
//! `SPEC.md` for the full grammar.

use std::io::Write;

use crate::edit::{Edit, ScriptLine, Tag};
use crate::error::Error;

/// A parsed request. Lines borrow from the input buffer.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Request<'a> {
    /// Diff `a` against `b`.
    Diff {
        /// Lines of the old file.
        a: Vec<&'a [u8]>,
        /// Lines of the new file.
        b: Vec<&'a [u8]>,
    },
    /// Apply `script` to `a`.
    Patch {
        /// Lines of the old file.
        a: Vec<&'a [u8]>,
        /// The edit script.
        script: Vec<ScriptLine<&'a [u8]>>,
    },
}

/// Splits the input into `\n`-terminated lines (the last may lack the `\n`).
struct Lines<'a> {
    rest: &'a [u8],
}

impl<'a> Lines<'a> {
    fn next_line(&mut self) -> Option<&'a [u8]> {
        if self.rest.is_empty() {
            return None;
        }
        match self.rest.iter().position(|&c| c == b'\n') {
            Some(p) => {
                let line = &self.rest[..p];
                self.rest = &self.rest[p + 1..];
                Some(line)
            }
            None => {
                let line = self.rest;
                self.rest = &[];
                Some(line)
            }
        }
    }

    fn need(&mut self, what: &str) -> Result<&'a [u8], Error> {
        self.next_line()
            .ok_or_else(|| Error::Parse(format!("unexpected end of input, expected {what}")))
    }

    /// Reads a count line: ASCII digits, trailing spaces/tabs/`\r` ignored.
    fn count(&mut self, what: &str) -> Result<usize, Error> {
        let line = self.need(what)?;
        let mut end = line.len();
        while end > 0 && matches!(line[end - 1], b' ' | b'\t' | b'\r') {
            end -= 1;
        }
        let digits = &line[..end];
        if digits.is_empty() || !digits.iter().all(u8::is_ascii_digit) {
            return Err(Error::Parse(format!("bad {what} line: {:?}", String::from_utf8_lossy(line))));
        }
        std::str::from_utf8(digits)
            .ok()
            .and_then(|s| s.parse().ok())
            .ok_or_else(|| Error::Parse(format!("{what} out of range")))
    }

    fn block(&mut self, what: &str) -> Result<Vec<&'a [u8]>, Error> {
        let n = self.count(what)?;
        // Cap the pre-allocation: the count is untrusted.
        let mut v = Vec::with_capacity(n.min(1 << 20));
        for _ in 0..n {
            v.push(self.need("a content line")?);
        }
        Ok(v)
    }
}

/// Parses a request from raw input bytes.
pub fn parse_request(input: &[u8]) -> Result<Request<'_>, Error> {
    let mut lines = Lines { rest: input };
    let mode = lines.need("the mode line")?;
    let mode = match mode.strip_suffix(b"\r") {
        Some(m) => m,
        None => mode,
    };
    match mode {
        b"diff" => {
            let a = lines.block("N")?;
            let b = lines.block("M")?;
            Ok(Request::Diff { a, b })
        }
        b"patch" => {
            let a = lines.block("N")?;
            let k = lines.count("K")?;
            let mut script = Vec::with_capacity(k.min(1 << 20));
            for n in 0..k {
                let line = lines.need("a script line")?;
                let tag = line
                    .first()
                    .and_then(|&c| Tag::from_byte(c))
                    .ok_or_else(|| Error::Parse(format!("script line {} has no valid tag", n + 1)))?;
                script.push(ScriptLine {
                    tag,
                    text: &line[1..],
                });
            }
            Ok(Request::Patch { a, script })
        }
        _ => Err(Error::Parse("mode must be `diff` or `patch`".into())),
    }
}

/// Writes a diff result: the script line count, then one line per edit.
pub fn write_script<W: Write>(
    out: &mut W,
    a: &[&[u8]],
    b: &[&[u8]],
    edits: &[Edit],
) -> std::io::Result<()> {
    writeln!(out, "{}", edits.len())?;
    for e in edits {
        let (tag, text) = match *e {
            Edit::Keep { a: i, .. } => (Tag::Keep, a[i]),
            Edit::Delete { a: i } => (Tag::Delete, a[i]),
            Edit::Insert { b: j } => (Tag::Insert, b[j]),
        };
        out.write_all(&[tag.as_byte()])?;
        out.write_all(text)?;
        out.write_all(b"\n")?;
    }
    Ok(())
}

/// Writes a patch result: the line count, then the lines.
pub fn write_lines<W: Write>(out: &mut W, lines: &[&[u8]]) -> std::io::Result<()> {
    writeln!(out, "{}", lines.len())?;
    for l in lines {
        out.write_all(l)?;
        out.write_all(b"\n")?;
    }
    Ok(())
}

/// Handles one whole request: parses `input`, runs diff or patch and writes
/// the response to `out`.
pub fn run<W: Write>(input: &[u8], out: &mut W) -> Result<(), Error> {
    match parse_request(input)? {
        Request::Diff { a, b } => {
            let edits = crate::diff::diff(&a, &b);
            write_script(out, &a, &b, &edits)?;
        }
        Request::Patch { a, script } => {
            let result = crate::patch::patch(&a, &script)?;
            write_lines(out, &result)?;
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn run_str(input: &str) -> Result<String, Error> {
        let mut out = Vec::new();
        run(input.as_bytes(), &mut out)?;
        Ok(String::from_utf8(out).unwrap())
    }

    #[test]
    fn lines_that_look_like_counts_and_tags() {
        let out = run_str("diff\n2\n5\n-\n2\n5\n+x\n").unwrap();
        assert_eq!(out, "3\n 5\n--\n++x\n");
    }

    #[test]
    fn patch_with_odd_lines() {
        let out = run_str("patch\n1\n \n3\n  \n+-x\n+\n").unwrap();
        assert_eq!(out, "3\n \n-x\n\n");
    }

    #[test]
    fn lenient_input() {
        assert_eq!(run_str("diff\n0 \n0").unwrap(), "0\n");
        assert_eq!(run_str("diff\n0\n0\n\n\n").unwrap(), "0\n");
    }

    #[test]
    fn errors() {
        assert!(run_str("bogus\n").is_err());
        assert!(run_str("diff\n2\na\n").is_err());
        assert!(run_str("diff\nx\n").is_err());
        assert!(run_str("patch\n0\n1\n?a\n").is_err());
    }
}
