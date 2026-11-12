//! The textual command language: parsing of command lines.

use std::error::Error;
use std::fmt;

/// A direction for [`Command::Move`].
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Direction {
    /// One character left, wrapping to the previous line.
    Left,
    /// One character right, wrapping to the next line.
    Right,
    /// One line up, aiming for the goal column.
    Up,
    /// One line down, aiming for the goal column.
    Down,
    /// Start of the line.
    Home,
    /// End of the line.
    End,
}

/// A parsed command line.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Command {
    /// `insert <text>`: the text is already decoded (real newlines).
    Insert(String),
    /// `delete`: backspace.
    Delete,
    /// `delete-forward`.
    DeleteForward,
    /// `move <dir> [select]`.
    Move {
        /// Where to move.
        dir: Direction,
        /// Whether to extend the selection.
        select: bool,
    },
    /// `goto <line> <col>` (clamped when executed).
    Goto(usize, usize),
    /// `add-cursor <line> <col>` (clamped when executed).
    AddCursor(usize, usize),
    /// `clear-cursors`.
    ClearCursors,
    /// `undo`.
    Undo,
    /// `redo`.
    Redo,
    /// `print`.
    Print,
}

/// Why a command line could not be parsed.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ParseError {
    /// The command word is not known.
    UnknownCommand(String),
    /// The arguments are missing, extra or malformed.
    BadArguments(&'static str),
    /// `insert` text with a backslash not followed by `n` or `\`.
    BadEscape,
}

impl fmt::Display for ParseError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ParseError::UnknownCommand(c) => write!(f, "unknown command {c:?}"),
            ParseError::BadArguments(cmd) => write!(f, "bad arguments for `{cmd}`"),
            ParseError::BadEscape => write!(f, "invalid escape sequence in insert text"),
        }
    }
}

impl Error for ParseError {}

/// Decodes the argument of `insert`: `\n` becomes a newline and `\\` one
/// backslash. Any other backslash sequence is an error.
pub fn decode_insert_text(raw: &str) -> Result<String, ParseError> {
    let mut out = String::with_capacity(raw.len());
    let mut chars = raw.chars();
    while let Some(c) = chars.next() {
        if c != '\\' {
            out.push(c);
            continue;
        }
        match chars.next() {
            Some('n') => out.push('\n'),
            Some('\\') => out.push('\\'),
            _ => return Err(ParseError::BadEscape),
        }
    }
    Ok(out)
}

fn parse_number(word: Option<&str>, cmd: &'static str) -> Result<usize, ParseError> {
    let w = word.ok_or(ParseError::BadArguments(cmd))?;
    if w.is_empty() || !w.bytes().all(|b| b.is_ascii_digit()) {
        return Err(ParseError::BadArguments(cmd));
    }
    // Absurdly large values behave like any out-of-range value: clamped later.
    Ok(w.parse().unwrap_or(usize::MAX))
}

impl Command {
    /// Parses one command line (without its line terminator).
    pub fn parse(line: &str) -> Result<Command, ParseError> {
        let (word, rest) = match line.split_once(' ') {
            Some((w, r)) => (w, Some(r)),
            None => (line, None),
        };
        let no_args = |cmd: Command, name: &'static str| {
            if rest.is_none() {
                Ok(cmd)
            } else {
                Err(ParseError::BadArguments(name))
            }
        };
        match word {
            "insert" => match rest {
                Some(text) if !text.is_empty() => Ok(Command::Insert(decode_insert_text(text)?)),
                _ => Err(ParseError::BadArguments("insert")),
            },
            "delete" => no_args(Command::Delete, "delete"),
            "delete-forward" => no_args(Command::DeleteForward, "delete-forward"),
            "clear-cursors" => no_args(Command::ClearCursors, "clear-cursors"),
            "undo" => no_args(Command::Undo, "undo"),
            "redo" => no_args(Command::Redo, "redo"),
            "print" => no_args(Command::Print, "print"),
            "move" => {
                let mut it = rest.unwrap_or("").split(' ');
                let dir = match it.next() {
                    Some("left") => Direction::Left,
                    Some("right") => Direction::Right,
                    Some("up") => Direction::Up,
                    Some("down") => Direction::Down,
                    Some("home") => Direction::Home,
                    Some("end") => Direction::End,
                    _ => return Err(ParseError::BadArguments("move")),
                };
                let select = match (it.next(), it.next()) {
                    (None, _) => false,
                    (Some("select"), None) => true,
                    _ => return Err(ParseError::BadArguments("move")),
                };
                Ok(Command::Move { dir, select })
            }
            "goto" | "add-cursor" => {
                let name = if word == "goto" { "goto" } else { "add-cursor" };
                let mut it = rest.unwrap_or("").split(' ');
                let line = parse_number(it.next(), name)?;
                let col = parse_number(it.next(), name)?;
                if it.next().is_some() {
                    return Err(ParseError::BadArguments(name));
                }
                Ok(if word == "goto" {
                    Command::Goto(line, col)
                } else {
                    Command::AddCursor(line, col)
                })
            }
            other => Err(ParseError::UnknownCommand(other.to_string())),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decodes_escapes() {
        assert_eq!(decode_insert_text(r"a\nb").unwrap(), "a\nb");
        assert_eq!(decode_insert_text(r"a\\nb").unwrap(), "a\\nb");
        assert_eq!(decode_insert_text(r"\\\\").unwrap(), "\\\\");
        assert_eq!(decode_insert_text(r"\x"), Err(ParseError::BadEscape));
        assert_eq!(decode_insert_text("a\\"), Err(ParseError::BadEscape));
    }

    #[test]
    fn insert_keeps_leading_and_trailing_spaces() {
        assert_eq!(
            Command::parse("insert  x "),
            Ok(Command::Insert(" x ".into()))
        );
        assert!(Command::parse("insert").is_err());
        assert!(Command::parse("insert ").is_err());
    }

    #[test]
    fn parses_moves() {
        assert_eq!(
            Command::parse("move up"),
            Ok(Command::Move {
                dir: Direction::Up,
                select: false
            })
        );
        assert_eq!(
            Command::parse("move end select"),
            Ok(Command::Move {
                dir: Direction::End,
                select: true
            })
        );
        assert!(Command::parse("move").is_err());
        assert!(Command::parse("move sideways").is_err());
        assert!(Command::parse("move up selec").is_err());
    }

    #[test]
    fn parses_positions() {
        assert_eq!(Command::parse("goto 3 4"), Ok(Command::Goto(3, 4)));
        assert_eq!(
            Command::parse("add-cursor 0 1000000000"),
            Ok(Command::AddCursor(0, 1_000_000_000))
        );
        assert!(Command::parse("goto 3").is_err());
        assert!(Command::parse("goto -1 0").is_err());
        assert!(Command::parse("goto 1 2 3").is_err());
    }

    #[test]
    fn parses_simple_commands() {
        assert_eq!(Command::parse("undo"), Ok(Command::Undo));
        assert_eq!(Command::parse("print"), Ok(Command::Print));
        assert_eq!(Command::parse("clear-cursors"), Ok(Command::ClearCursors));
        assert!(Command::parse("undo now").is_err());
        assert_eq!(
            Command::parse("jump"),
            Err(ParseError::UnknownCommand("jump".into()))
        );
    }
}
