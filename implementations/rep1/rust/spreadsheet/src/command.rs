//! The line-oriented command language used by the command-line tool.
//!
//! ```text
//! set <CELL> <content>
//! get <CELL>
//! clear <CELL>
//! dump
//! ```

use crate::cell::CellRef;
use crate::error::Error;
use crate::sheet::{Content, Sheet};
use std::io::{self, Write};

/// One parsed command.
#[derive(Clone, PartialEq, Debug)]
pub enum Command {
    /// `set <CELL> <content>`
    Set(CellRef, Content),
    /// `get <CELL>`
    Get(CellRef),
    /// `clear <CELL>`
    Clear(CellRef),
    /// `dump`
    Dump,
}

impl Command {
    /// Parses a single command line (without its line terminator).
    pub fn parse(line: &str) -> Result<Command, Error> {
        let bad = || Error::InvalidCommand(line.to_string());
        let cell = |name: &str| CellRef::parse(name).ok_or_else(|| Error::InvalidCell(name.to_string()));
        let mut parts = line.splitn(3, ' ');
        match (parts.next(), parts.next(), parts.next()) {
            (Some("set"), Some(name), Some(content)) => Ok(Command::Set(cell(name)?, Content::parse(content)?)),
            (Some("get"), Some(name), None) => Ok(Command::Get(cell(name)?)),
            (Some("clear"), Some(name), None) => Ok(Command::Clear(cell(name)?)),
            (Some("dump"), None, None) => Ok(Command::Dump),
            _ => Err(bad()),
        }
    }

    /// Applies the command to `sheet`, writing any output to `out`.
    pub fn execute<W: Write>(&self, sheet: &mut Sheet, out: &mut W) -> io::Result<()> {
        match self {
            Command::Set(cell, content) => sheet.set(*cell, content.clone()),
            Command::Clear(cell) => sheet.clear(*cell),
            Command::Get(cell) => writeln!(out, "{}", sheet.get(*cell))?,
            Command::Dump => {
                for (cell, value) in sheet.dump() {
                    writeln!(out, "{cell} {value}")?;
                }
            }
        }
        Ok(())
    }
}

/// Runs a whole script against a fresh sheet, writing the output of `get` and
/// `dump` commands to `out`.
///
/// Lines that cannot be parsed are skipped; their errors are returned (with
/// the 1-based line number) after the rest of the script has run. I/O errors
/// abort immediately.
pub fn run_script<W: Write>(input: &str, out: &mut W) -> io::Result<Vec<(usize, Error)>> {
    let mut sheet = Sheet::new();
    let mut errors = Vec::new();
    for (i, line) in input.lines().enumerate() {
        match Command::parse(line) {
            Ok(cmd) => cmd.execute(&mut sheet, out)?,
            Err(e) => errors.push((i + 1, e)),
        }
    }
    Ok(errors)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn run(input: &str) -> String {
        let mut out = Vec::new();
        let errors = run_script(input, &mut out).unwrap();
        assert!(errors.is_empty(), "{errors:?}");
        String::from_utf8(out).unwrap()
    }

    #[test]
    fn parse_commands() {
        assert_eq!(Command::parse("dump").unwrap(), Command::Dump);
        assert!(matches!(Command::parse("get A1").unwrap(), Command::Get(_)));
        assert!(matches!(Command::parse("clear B2").unwrap(), Command::Clear(_)));
        assert!(matches!(Command::parse("set A1 \"a b\"").unwrap(), Command::Set(_, Content::Text(_))));
        assert!(Command::parse("frob A1").is_err());
        assert!(Command::parse("get a1").is_err());
        assert!(Command::parse("set A1").is_err());
    }

    #[test]
    fn crlf_is_not_special_but_final_line_may_lack_newline() {
        assert_eq!(run("set A1 1\nget A1"), "1\n");
    }

    #[test]
    fn bad_lines_are_reported() {
        let mut out = Vec::new();
        let errors = run_script("get A1\nnonsense\nget A1\n", &mut out).unwrap();
        assert_eq!(errors.len(), 1);
        assert_eq!(errors[0].0, 2);
        assert_eq!(out, b"\n\n");
    }
}
