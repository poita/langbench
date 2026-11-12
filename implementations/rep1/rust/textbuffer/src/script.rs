//! Running a whole input script: initial document followed by commands.

use crate::buffer::Buffer;
use crate::command::{Command, ParseError};
use crate::document::Document;
use std::error::Error;
use std::fmt;
use std::io::{self, Write};

/// Why running a script failed.
#[derive(Debug)]
pub enum ScriptError {
    /// The input is not valid UTF-8.
    NotUtf8,
    /// The first line is not a line count.
    BadHeader,
    /// The initial document contains a non-ASCII character.
    NonAscii,
    /// A command line failed to parse (1-based input line number).
    Parse {
        /// Line number in the input.
        line: usize,
        /// The parse failure.
        error: ParseError,
    },
    /// Writing the output failed.
    Io(io::Error),
}

impl fmt::Display for ScriptError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ScriptError::NotUtf8 => f.write_str("input is not valid UTF-8"),
            ScriptError::BadHeader => {
                f.write_str("first line must be the number of document lines")
            }
            ScriptError::NonAscii => f.write_str("input contains non-ASCII text"),
            ScriptError::Parse { line, error } => write!(f, "line {line}: {error}"),
            ScriptError::Io(e) => write!(f, "write error: {e}"),
        }
    }
}

impl Error for ScriptError {}

impl From<io::Error> for ScriptError {
    fn from(e: io::Error) -> Self {
        ScriptError::Io(e)
    }
}

/// Runs a script: a line count `N`, `N` document lines taken verbatim, then
/// one command per line until the end of the input. The output of every
/// `print` command is written to `out`.
///
/// The final input line may omit its terminating newline. Empty lines after
/// the document are ignored. Missing document lines (input ended early) are
/// taken to be empty.
pub fn run<W: Write>(input: &[u8], out: &mut W) -> Result<(), ScriptError> {
    let text = std::str::from_utf8(input).map_err(|_| ScriptError::NotUtf8)?;
    if !text.is_ascii() {
        return Err(ScriptError::NonAscii);
    }
    let mut lines = text.split('\n');
    let n: usize = lines
        .next()
        .and_then(|l| l.trim().parse().ok())
        .ok_or(ScriptError::BadHeader)?;
    let mut doc_lines = Vec::with_capacity(n.min(1 << 20));
    for _ in 0..n {
        doc_lines.push(lines.next().unwrap_or("").to_string());
    }
    let mut buffer = Buffer::new(Document::from_lines(doc_lines));
    for (i, line) in lines.enumerate() {
        if line.is_empty() {
            continue;
        }
        let command = Command::parse(line).map_err(|error| ScriptError::Parse {
            line: n + 2 + i,
            error,
        })?;
        buffer.execute(&command, out)?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn run_str(input: &str) -> String {
        let mut out = Vec::new();
        run(input.as_bytes(), &mut out).unwrap();
        String::from_utf8(out).unwrap()
    }

    #[test]
    fn zero_lines_is_an_empty_document() {
        assert_eq!(run_str("0\nprint\n"), "\ncursor 0 0\n--\n");
    }

    #[test]
    fn last_line_may_lack_newline() {
        assert_eq!(run_str("1\nab\nmove end\nprint"), "ab\ncursor 0 2\n--\n");
    }

    #[test]
    fn document_lines_are_verbatim() {
        // A document line that looks like a command is just text.
        assert_eq!(
            run_str("2\nprint\n  x \nprint\n"),
            "print\n  x \ncursor 0 0\n--\n"
        );
    }

    #[test]
    fn no_print_no_output() {
        assert_eq!(run_str("1\nabc\ninsert x\n"), "");
    }

    #[test]
    fn reports_bad_input() {
        let mut out = Vec::new();
        assert!(matches!(run(b"x\n", &mut out), Err(ScriptError::BadHeader)));
        assert!(matches!(
            run(b"0\nfly\n", &mut out),
            Err(ScriptError::Parse { line: 2, .. })
        ));
        assert!(matches!(
            run(&[b'0', b'\n', 0xff], &mut out),
            Err(ScriptError::NotUtf8)
        ));
    }
}
