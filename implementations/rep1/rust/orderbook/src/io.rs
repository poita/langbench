//! Text front end: reads the command stream format and writes events.

use crate::book::OrderBook;
use crate::command::{Command, ParseError};
use crate::event::{Event, EventSink};
use std::fmt;
use std::io::{self, Write};

/// Error from [`process`].
#[derive(Debug)]
pub enum ProcessError {
    /// The first line is missing or not a valid command count.
    BadHeader,
    /// A command line could not be parsed (1-based line number in the input).
    Parse {
        /// Line number of the offending line.
        line: usize,
        /// The parse failure.
        error: ParseError,
    },
    /// Fewer command lines than announced.
    Truncated,
    /// Writing the output failed.
    Io(io::Error),
}

impl fmt::Display for ProcessError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ProcessError::BadHeader => f.write_str("first line must be the command count"),
            ProcessError::Parse { line, error } => write!(f, "line {line}: {error}"),
            ProcessError::Truncated => f.write_str("fewer commands than announced"),
            ProcessError::Io(e) => write!(f, "write error: {e}"),
        }
    }
}

impl std::error::Error for ProcessError {}

impl From<io::Error> for ProcessError {
    fn from(e: io::Error) -> Self {
        ProcessError::Io(e)
    }
}

const FLUSH_AT: usize = 1 << 16;

/// An [`EventSink`] that formats events into a buffer and flushes it to a
/// writer in large chunks. The first I/O error is remembered.
struct WriteSink<W: Write> {
    out: W,
    buf: Vec<u8>,
    error: Option<io::Error>,
}

impl<W: Write> WriteSink<W> {
    fn flush_buf(&mut self) {
        if self.error.is_none() {
            if let Err(e) = self.out.write_all(&self.buf) {
                self.error = Some(e);
            }
        }
        self.buf.clear();
    }
}

impl<W: Write> EventSink for WriteSink<W> {
    #[inline]
    fn emit(&mut self, event: Event) {
        event.write_to(&mut self.buf);
        self.buf.push(b'\n');
        if self.buf.len() >= FLUSH_AT {
            self.flush_buf();
        }
    }
}

/// Runs a whole command stream.
///
/// `input` is the text format of the specification: a line with the command
/// count `N`, then `N` command lines. Events are written to `out`, one per
/// line. Output is produced as commands are executed.
///
/// ```
/// let mut out = Vec::new();
/// orderbook::process("2\nLIMIT a BUY 5 1\nBOOK\n", &mut out).unwrap();
/// assert_eq!(String::from_utf8(out).unwrap(), "REST a\nBID 5 1 1\n--\n");
/// ```
pub fn process<W: Write>(input: &str, out: W) -> Result<(), ProcessError> {
    let mut lines = input.lines();
    let n: usize = lines
        .next()
        .and_then(|l| l.trim_end_matches('\r').parse().ok())
        .ok_or(ProcessError::BadHeader)?;
    let mut book = OrderBook::new();
    let mut sink = WriteSink { out, buf: Vec::with_capacity(FLUSH_AT * 2), error: None };
    for i in 0..n {
        let line = lines.next().ok_or(ProcessError::Truncated)?;
        let cmd = Command::parse(line.trim_end_matches('\r'))
            .map_err(|error| ProcessError::Parse { line: i + 2, error })?;
        book.execute(&cmd, &mut sink);
        if sink.error.is_some() {
            break;
        }
    }
    sink.flush_buf();
    if let Some(e) = sink.error.take() {
        return Err(e.into());
    }
    sink.out.flush()?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn run(input: &str) -> Result<String, ProcessError> {
        let mut out = Vec::new();
        process(input, &mut out)?;
        Ok(String::from_utf8(out).unwrap())
    }

    #[test]
    fn empty_stream() {
        assert_eq!(run("0\n").unwrap(), "");
        assert_eq!(run("0").unwrap(), "");
    }

    #[test]
    fn missing_final_newline() {
        assert_eq!(run("1\nBOOK").unwrap(), "--\n");
    }

    #[test]
    fn errors() {
        assert!(matches!(run(""), Err(ProcessError::BadHeader)));
        assert!(matches!(run("2\nBOOK\n"), Err(ProcessError::Truncated)));
        assert!(matches!(run("1\nNOPE\n"), Err(ProcessError::Parse { line: 2, .. })));
    }
}
