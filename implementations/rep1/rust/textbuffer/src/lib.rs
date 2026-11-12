//! # textbuffer
//!
//! The editing core of a text editor: a document made of lines, a set of
//! cursors (each optionally holding a selection), insertion and deletion at
//! every cursor, cursor movement with a remembered goal column, and
//! undo/redo.
//!
//! Text is printable ASCII, so a column is both a character index and a byte
//! index. Lines are stored as a vector of strings: edits cost `O(line length)`
//! and adding or removing lines costs `O(number of lines)`.
//!
//! ## Modules
//!
//! * [`position`]: [`Position`], a `(line, col)` pair.
//! * [`document`]: [`Document`], the lines of text and the splice primitive.
//! * [`cursor`]: [`Cursor`] and [`normalize`](cursor::normalize), which merges
//!   colliding cursors.
//! * [`history`]: undo/redo [`Entry`](history::Entry) records (cursors and
//!   replacements, never document copies).
//! * [`buffer`]: [`Buffer`], tying the three together with the commands.
//! * [`command`]: the textual command language ([`Command`]).
//! * [`script`]: running a complete input script, as the CLI does.
//!
//! ## Example
//!
//! ```
//! use textbuffer::{Buffer, Direction, Position};
//!
//! let mut buf = Buffer::from_text("alpha\nbeta\ngamma");
//! buf.add_cursor(1, 0);
//! buf.add_cursor(2, 0);
//! buf.insert("- ").unwrap();
//! assert_eq!(buf.text(), "- alpha\n- beta\n- gamma");
//! assert_eq!(buf.cursors().len(), 3);
//!
//! buf.move_cursors(Direction::End, true); // select to end of line
//! buf.insert("X").unwrap();
//! assert_eq!(buf.text(), "- X\n- X\n- X");
//!
//! buf.undo(); // one undo step per edit command
//! assert_eq!(buf.text(), "- alpha\n- beta\n- gamma");
//! // The cursors are restored too, selections included.
//! assert_eq!(buf.cursors()[0].head, Position::new(0, 7));
//! assert_eq!(buf.cursors()[0].anchor, Some(Position::new(0, 2)));
//! ```

pub mod buffer;
pub mod command;
pub mod cursor;
pub mod document;
pub mod history;
pub mod position;
pub mod script;

pub use buffer::{Buffer, NonAsciiError};
pub use command::{Command, Direction, ParseError};
pub use cursor::Cursor;
pub use document::Document;
pub use position::Position;
