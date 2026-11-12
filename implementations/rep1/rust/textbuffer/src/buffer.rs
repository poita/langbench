//! The buffer: document, cursors and history, with the editing commands.

use crate::command::{Command, Direction};
use crate::cursor::{normalize, Cursor};
use crate::document::{end_of_text, Document};
use crate::history::{Entry, History, Replacement};
use crate::position::Position;
use std::error::Error;
use std::fmt;
use std::io::{self, Write};

/// Error returned by [`Buffer::insert`] for text it cannot hold.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct NonAsciiError;

impl fmt::Display for NonAsciiError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("buffers hold ASCII text only")
    }
}

impl Error for NonAsciiError {}

/// Maps positions of the document as it was before an edit command into the
/// document as it is after the replacements made so far.
///
/// Cursors are visited in order and their ranges never overlap, so every
/// not-yet-visited position lies at or after the end of the most recent
/// replacement. That replacement alone (together with the line-count change
/// accumulated so far, which it already includes) determines the shift, so
/// mapping a position takes O(1).
#[derive(Clone, Copy)]
struct Shift {
    /// End of the latest replaced range, in pre-command coordinates.
    old_end: Position,
    /// Where that end now is (the cursor after the inserted text).
    new_end: Position,
}

impl Shift {
    #[inline]
    fn apply(&self, p: Position) -> Position {
        if p.line == self.old_end.line {
            Position::new(
                self.new_end.line,
                self.new_end.col + (p.col - self.old_end.col),
            )
        } else {
            Position::new(p.line + self.new_end.line - self.old_end.line, p.col)
        }
    }
}

/// What an edit command does at each cursor without a selection.
#[derive(Clone, Copy)]
enum Edit<'a> {
    Insert(&'a str),
    Backspace,
    DeleteForward,
}

/// A text buffer with multiple cursors and undo/redo.
///
/// The buffer starts with one primary cursor at `(0, 0)` and empty history.
/// Every command other than [`Buffer::undo`], [`Buffer::redo`] and the
/// cursor queries keeps the cursor set normalized (see
/// [`normalize`](crate::cursor::normalize)): sorted in cursor order, with
/// colliding cursors merged.
#[derive(Clone, Debug)]
pub struct Buffer {
    doc: Document,
    cursors: Vec<Cursor>,
    history: History,
}

impl Default for Buffer {
    fn default() -> Self {
        Buffer::new(Document::new())
    }
}

impl Buffer {
    /// Creates a buffer on `doc` with a single primary cursor at `(0, 0)`.
    pub fn new(doc: Document) -> Self {
        Buffer {
            doc,
            cursors: vec![Cursor::at(Position::new(0, 0), true)],
            history: History::new(),
        }
    }

    /// Creates a buffer from text (lines separated by `\n`).
    ///
    /// # Panics
    /// If the text is not ASCII.
    pub fn from_text(text: &str) -> Self {
        Buffer::new(Document::from_text(text))
    }

    /// The document.
    pub fn document(&self) -> &Document {
        &self.doc
    }

    /// The whole text of the document.
    pub fn text(&self) -> String {
        self.doc.text()
    }

    /// The cursors, in cursor order.
    pub fn cursors(&self) -> &[Cursor] {
        &self.cursors
    }

    /// The history of recorded edits.
    pub fn history(&self) -> &History {
        &self.history
    }

    // ---- editing ----------------------------------------------------------

    /// Inserts `text` at every cursor, replacing selections. `text` may
    /// contain `\n`. Returns whether the document changed (it does unless
    /// `text` is empty).
    pub fn insert(&mut self, text: &str) -> Result<bool, NonAsciiError> {
        if !text.is_ascii() {
            return Err(NonAsciiError);
        }
        Ok(self.edit(Edit::Insert(text)))
    }

    /// Backspace: deletes every selection, or the character before each
    /// cursor. Returns whether the document changed.
    pub fn delete(&mut self) -> bool {
        self.edit(Edit::Backspace)
    }

    /// Deletes every selection, or the character after each cursor. Returns
    /// whether the document changed.
    pub fn delete_forward(&mut self) -> bool {
        self.edit(Edit::DeleteForward)
    }

    /// Applies one edit to all cursors in cursor order, recording an undo
    /// entry when the document changed.
    fn edit(&mut self, kind: Edit<'_>) -> bool {
        let before = std::mem::take(&mut self.cursors);
        let mut after: Vec<Cursor> = Vec::with_capacity(before.len());
        let mut replacements: Vec<Replacement> = Vec::new();
        let mut shift: Option<Shift> = None;
        let map = |shift: &Option<Shift>, p: Position| match shift {
            Some(s) => s.apply(p),
            None => p,
        };

        for &old in &before {
            let head = map(&shift, old.head);
            let (start, end, old_end, text) = match old.anchor {
                Some(anchor) => {
                    let anchor = map(&shift, anchor);
                    let text = if let Edit::Insert(t) = kind { t } else { "" };
                    (anchor.min(head), anchor.max(head), old.end(), text)
                }
                None => match kind {
                    Edit::Insert(t) => (head, head, old.head, t),
                    Edit::Backspace => (self.doc.prev(head), head, old.head, ""),
                    Edit::DeleteForward => {
                        let next = self.doc.next(head);
                        // The same step in pre-command coordinates: the text after the
                        // cursor on its line is untouched by earlier replacements.
                        let old_next = if next.line == head.line {
                            Position::new(old.head.line, old.head.col + 1)
                        } else {
                            Position::new(old.head.line + 1, 0)
                        };
                        (head, next, old_next, "")
                    }
                },
            };
            if start == end && text.is_empty() {
                after.push(Cursor {
                    head,
                    anchor: None,
                    ..old
                });
                continue;
            }
            let removed = self.doc.text_between(start, end);
            self.doc.replace(start, end, text);
            let new_head = end_of_text(start, text);
            replacements.push(Replacement {
                start,
                removed: removed.into(),
                inserted: text.into(),
            });
            shift = Some(Shift {
                old_end,
                new_end: new_head,
            });
            after.push(Cursor {
                head: new_head,
                anchor: None,
                ..old
            });
        }

        self.cursors = after;
        self.finish(false);
        if replacements.is_empty() {
            return false;
        }
        self.history.record(Entry {
            before: before.into_boxed_slice(),
            after: self.cursors.clone().into_boxed_slice(),
            replacements: replacements.into_boxed_slice(),
        });
        true
    }

    // ---- cursors ----------------------------------------------------------

    /// Moves every cursor, optionally extending selections, then normalizes.
    pub fn move_cursors(&mut self, dir: Direction, select: bool) {
        for c in &mut self.cursors {
            move_cursor(&self.doc, c, dir, select);
        }
        self.finish(matches!(dir, Direction::Up | Direction::Down));
    }

    /// Replaces all cursors with one primary cursor at the clamped position.
    pub fn goto(&mut self, line: usize, col: usize) {
        let p = self.doc.clamp(line, col);
        self.cursors = vec![Cursor::at(p, true)];
        self.finish(false);
    }

    /// Adds a non-primary cursor at the clamped position; it merges with any
    /// cursor whose range contains that position.
    pub fn add_cursor(&mut self, line: usize, col: usize) {
        let p = self.doc.clamp(line, col);
        self.cursors.push(Cursor::at(p, false));
        self.finish(false);
    }

    /// Removes every cursor except the primary one (which keeps its selection).
    pub fn clear_cursors(&mut self) {
        self.cursors.retain(|c| c.primary);
        self.finish(false);
    }

    /// Normalizes the cursor set and, unless the command was a vertical
    /// move, resets every goal column to the column of its head.
    fn finish(&mut self, keep_goals: bool) {
        normalize(&mut self.cursors);
        if !keep_goals {
            for c in &mut self.cursors {
                c.goal = c.head.col;
            }
        }
    }

    // ---- history ----------------------------------------------------------

    /// Reverts the most recent edit command. Returns false if there is none.
    pub fn undo(&mut self) -> bool {
        let Some(entry) = self.history.undo() else {
            self.finish(false); // like every command, resets the goal columns
            return false;
        };
        for r in entry.replacements.iter().rev() {
            let end = end_of_text(r.start, &r.inserted);
            self.doc.replace(r.start, end, &r.removed);
        }
        self.cursors = entry.before.to_vec();
        self.finish(false);
        true
    }

    /// Re-applies the most recently undone edit. Returns false if there is none.
    pub fn redo(&mut self) -> bool {
        let Some(entry) = self.history.redo() else {
            self.finish(false);
            return false;
        };
        for r in entry.replacements.iter() {
            let end = end_of_text(r.start, &r.removed);
            self.doc.replace(r.start, end, &r.inserted);
        }
        self.cursors = entry.after.to_vec();
        self.finish(false);
        true
    }

    // ---- commands and output ----------------------------------------------

    /// Executes a parsed command. [`Command::Print`] writes the snapshot to
    /// `out`; nothing else writes.
    pub fn execute<W: Write>(&mut self, command: &Command, out: &mut W) -> io::Result<()> {
        match command {
            Command::Insert(text) => {
                // Command text is decoded ASCII; non-ASCII input is skipped.
                let _ = self.insert(text);
            }
            Command::Delete => {
                self.delete();
            }
            Command::DeleteForward => {
                self.delete_forward();
            }
            Command::Move { dir, select } => self.move_cursors(*dir, *select),
            Command::Goto(l, c) => self.goto(*l, *c),
            Command::AddCursor(l, c) => self.add_cursor(*l, *c),
            Command::ClearCursors => self.clear_cursors(),
            Command::Undo => {
                self.undo();
            }
            Command::Redo => {
                self.redo();
            }
            Command::Print => self.write_snapshot(out)?,
        }
        Ok(())
    }

    /// Writes every line followed by `\n`, then `cursor <line> <col>` for
    /// each cursor head in cursor order, then `--`.
    pub fn write_snapshot<W: Write>(&self, out: &mut W) -> io::Result<()> {
        for line in self.doc.lines() {
            out.write_all(line.as_bytes())?;
            out.write_all(b"\n")?;
        }
        for c in &self.cursors {
            writeln!(out, "cursor {} {}", c.head.line, c.head.col)?;
        }
        out.write_all(b"--\n")
    }
}

/// Moves one cursor (without normalizing).
fn move_cursor(doc: &Document, c: &mut Cursor, dir: Direction, select: bool) {
    if !select {
        if let (true, Direction::Left | Direction::Right) = (c.has_selection(), dir) {
            c.head = if dir == Direction::Left {
                c.start()
            } else {
                c.end()
            };
            c.anchor = None;
            return;
        }
        c.anchor = None;
    } else if c.anchor.is_none() {
        c.anchor = Some(c.head);
    }
    let line = c.head.line;
    c.head = match dir {
        Direction::Left => doc.prev(c.head),
        Direction::Right => doc.next(c.head),
        Direction::Home => Position::new(line, 0),
        Direction::End => Position::new(line, doc.line_len(line)),
        Direction::Up => {
            if line == 0 {
                c.goal = 0;
                Position::new(0, 0)
            } else {
                Position::new(line - 1, c.goal.min(doc.line_len(line - 1)))
            }
        }
        Direction::Down => {
            if line + 1 == doc.line_count() {
                let end = doc.end();
                c.goal = end.col;
                end
            } else {
                Position::new(line + 1, c.goal.min(doc.line_len(line + 1)))
            }
        }
    };
    if c.anchor == Some(c.head) {
        c.anchor = None;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn p(l: usize, c: usize) -> Position {
        Position::new(l, c)
    }

    fn heads(b: &Buffer) -> Vec<Position> {
        b.cursors().iter().map(|c| c.head).collect()
    }

    #[test]
    fn starts_with_one_primary_cursor() {
        let b = Buffer::from_text("abc");
        assert_eq!(b.cursors().len(), 1);
        assert!(b.cursors()[0].primary);
        assert_eq!(heads(&b), vec![p(0, 0)]);
    }

    #[test]
    fn insert_and_backspace() {
        let mut b = Buffer::from_text("ab");
        b.move_cursors(Direction::End, false);
        assert!(b.insert("c\nd").unwrap());
        assert_eq!(b.text(), "abc\nd");
        assert_eq!(heads(&b), vec![p(1, 1)]);
        assert!(b.delete());
        assert!(b.delete());
        assert_eq!(b.text(), "abc");
        assert!(b.delete());
        assert!(b.delete());
        assert!(b.delete());
        assert!(!b.delete(), "nothing left before the cursor");
    }

    #[test]
    fn insert_rejects_non_ascii() {
        let mut b = Buffer::default();
        assert_eq!(b.insert("é"), Err(NonAsciiError));
        assert_eq!(b.text(), "");
    }

    #[test]
    fn noop_edit_is_not_recorded_and_keeps_redo() {
        let mut b = Buffer::from_text("a");
        b.insert("x").unwrap();
        b.undo();
        assert_eq!(b.history().redo_len(), 1);
        assert!(!b.delete()); // at (0,0): nothing to delete
        assert_eq!(b.history().redo_len(), 1);
        assert!(b.redo());
        assert_eq!(b.text(), "xa");
    }

    #[test]
    fn adjacent_cursors_deleting_merge() {
        let mut b = Buffer::from_text("abcdef");
        b.goto(0, 3);
        b.add_cursor(0, 4);
        b.delete();
        assert_eq!(b.text(), "abef");
        assert_eq!(heads(&b), vec![p(0, 2)]);
    }

    #[test]
    fn multi_cursor_insert_shifts_later_cursors() {
        let mut b = Buffer::from_text("ab\ncd");
        b.goto(0, 1);
        b.add_cursor(0, 2);
        b.add_cursor(1, 1);
        b.insert("X\nY").unwrap();
        assert_eq!(b.text(), "aX\nYbX\nY\ncX\nYd");
        assert_eq!(heads(&b), vec![p(1, 1), p(2, 1), p(4, 1)]);
    }

    #[test]
    fn delete_forward_joins_lines_for_each_cursor() {
        let mut b = Buffer::from_text("a\nb\nc");
        b.goto(0, 1);
        b.add_cursor(1, 1);
        b.delete_forward();
        // The first cursor joins "a" and "b"; the second, at the end of "b",
        // then joins the result with "c".
        assert_eq!(b.text(), "abc");
        assert_eq!(heads(&b), vec![p(0, 1), p(0, 2)]);
    }

    #[test]
    fn goal_column_survives_vertical_moves_only() {
        let mut b = Buffer::from_text("abcdef\nab\nabcdef");
        b.goto(0, 5);
        b.move_cursors(Direction::Down, false);
        assert_eq!(heads(&b), vec![p(1, 2)]);
        b.move_cursors(Direction::Down, false);
        assert_eq!(heads(&b), vec![p(2, 5)]);
        b.move_cursors(Direction::Up, false);
        b.move_cursors(Direction::Left, false);
        b.move_cursors(Direction::Down, false);
        assert_eq!(heads(&b), vec![p(2, 1)]);
    }

    #[test]
    fn vertical_moves_at_document_edges() {
        let mut b = Buffer::from_text("abc\nde");
        b.goto(0, 2);
        b.move_cursors(Direction::Up, false);
        assert_eq!((heads(&b), b.cursors()[0].goal), (vec![p(0, 0)], 0));
        b.move_cursors(Direction::Down, false);
        b.move_cursors(Direction::Down, false);
        assert_eq!((heads(&b), b.cursors()[0].goal), (vec![p(1, 2)], 2));
    }

    #[test]
    fn selections_collapse_on_left_and_right() {
        let mut b = Buffer::from_text("abcdef");
        b.goto(0, 4);
        b.move_cursors(Direction::Left, true);
        b.move_cursors(Direction::Left, true);
        assert_eq!(b.cursors()[0].anchor, Some(p(0, 4)));
        b.move_cursors(Direction::Right, false);
        assert_eq!((heads(&b), b.cursors()[0].anchor), (vec![p(0, 4)], None));
        b.move_cursors(Direction::Left, true);
        b.move_cursors(Direction::Right, true);
        assert_eq!(
            b.cursors()[0].anchor,
            None,
            "head back on the anchor drops the selection"
        );
    }

    #[test]
    fn clear_cursors_keeps_primary_selection() {
        let mut b = Buffer::from_text("abcdef");
        b.move_cursors(Direction::Right, true);
        b.add_cursor(0, 5);
        b.clear_cursors();
        assert_eq!(b.cursors().len(), 1);
        assert!(b.cursors()[0].has_selection());
    }

    #[test]
    fn undo_restores_text_and_cursors_and_redo_reapplies() {
        let mut b = Buffer::from_text("one\ntwo");
        b.goto(0, 1);
        b.add_cursor(1, 1);
        b.move_cursors(Direction::End, true);
        let before = b.cursors().to_vec();
        b.insert("Q\nR").unwrap();
        let after = b.cursors().to_vec();
        assert_eq!(b.text(), "oQ\nR\ntQ\nR");
        assert!(b.undo());
        assert_eq!(b.text(), "one\ntwo");
        assert_eq!(
            b.cursors()
                .iter()
                .map(|c| (c.head, c.anchor, c.primary))
                .collect::<Vec<_>>(),
            before
                .iter()
                .map(|c| (c.head, c.anchor, c.primary))
                .collect::<Vec<_>>()
        );
        assert!(b.redo());
        assert_eq!(b.text(), "oQ\nR\ntQ\nR");
        assert_eq!(heads(&b), after.iter().map(|c| c.head).collect::<Vec<_>>());
        assert!(!b.redo());
    }

    #[test]
    fn undo_and_redo_without_history_reset_goal_columns() {
        let mut b = Buffer::from_text("abcdef\nab\nabcdef");
        b.goto(0, 5);
        b.move_cursors(Direction::Down, false); // (1, 2), goal 5
        assert_eq!(b.cursors()[0].goal, 5);
        assert!(!b.undo());
        assert_eq!(b.cursors()[0].goal, 2);
    }

    #[test]
    fn snapshot_format() {
        let mut b = Buffer::from_text("a\n\nb");
        b.add_cursor(2, 1);
        let mut out = Vec::new();
        b.write_snapshot(&mut out).unwrap();
        assert_eq!(
            String::from_utf8(out).unwrap(),
            "a\n\nb\ncursor 0 0\ncursor 2 1\n--\n"
        );
    }
}
