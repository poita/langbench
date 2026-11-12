//! Undo and redo bookkeeping.

use crate::cursor::Cursor;
use crate::position::Position;

/// One replacement made by an edit command: at `start`, the text `removed`
/// was replaced by `inserted`.
///
/// `start` is expressed in the document as it was immediately before this
/// replacement was applied, which is the coordinate system in which undo (in
/// reverse order) and redo (in forward order) re-apply it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Replacement {
    /// Where the replaced range begins.
    pub start: Position,
    /// The text that was removed (may be empty).
    pub removed: Box<str>,
    /// The text that was inserted (may be empty).
    pub inserted: Box<str>,
}

/// Everything needed to undo or redo one edit command: the cursor set
/// before and after it, and its replacements. Never a copy of the document.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Entry {
    /// Cursors before the command.
    pub before: Box<[Cursor]>,
    /// Cursors after the command (normalized).
    pub after: Box<[Cursor]>,
    /// The replacements in the order they were applied.
    pub replacements: Box<[Replacement]>,
}

/// The undo and redo stacks.
#[derive(Clone, Debug, Default)]
pub struct History {
    undo: Vec<Entry>,
    redo: Vec<Entry>,
}

impl History {
    /// Empty history.
    pub fn new() -> Self {
        History::default()
    }

    /// Records a new edit and clears the redo stack.
    pub fn record(&mut self, entry: Entry) {
        self.undo.push(entry);
        self.redo.clear();
    }

    /// Moves the most recent undo entry to the redo stack and returns it.
    pub fn undo(&mut self) -> Option<&Entry> {
        let e = self.undo.pop()?;
        self.redo.push(e);
        self.redo.last()
    }

    /// Moves the most recent redo entry back to the undo stack and returns it.
    pub fn redo(&mut self) -> Option<&Entry> {
        let e = self.redo.pop()?;
        self.undo.push(e);
        self.undo.last()
    }

    /// Number of entries that can be undone.
    pub fn undo_len(&self) -> usize {
        self.undo.len()
    }

    /// Number of entries that can be redone.
    pub fn redo_len(&self) -> usize {
        self.redo.len()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entry(tag: usize) -> Entry {
        Entry {
            before: Box::new([]),
            after: Box::new([]),
            replacements: Box::new([Replacement {
                start: Position::new(tag, 0),
                removed: "".into(),
                inserted: "x".into(),
            }]),
        }
    }

    #[test]
    fn undo_and_redo_move_entries_between_stacks() {
        let mut h = History::new();
        assert!(h.undo().is_none());
        assert!(h.redo().is_none());
        h.record(entry(1));
        h.record(entry(2));
        assert_eq!(h.undo().unwrap().replacements[0].start.line, 2);
        assert_eq!((h.undo_len(), h.redo_len()), (1, 1));
        assert_eq!(h.redo().unwrap().replacements[0].start.line, 2);
        assert_eq!((h.undo_len(), h.redo_len()), (2, 0));
    }

    #[test]
    fn recording_clears_redo() {
        let mut h = History::new();
        h.record(entry(1));
        h.undo();
        h.record(entry(2));
        assert_eq!(h.redo_len(), 0);
        assert!(h.redo().is_none());
    }
}
