//! Edit operations and script lines.

/// One step of an edit script, expressed with indices into the two inputs.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Edit {
    /// Line `a` of the old sequence equals line `b` of the new one.
    Keep {
        /// Index into the old sequence.
        a: usize,
        /// Index into the new sequence.
        b: usize,
    },
    /// Line `a` of the old sequence is removed.
    Delete {
        /// Index into the old sequence.
        a: usize,
    },
    /// Line `b` of the new sequence is added.
    Insert {
        /// Index into the new sequence.
        b: usize,
    },
}

/// Number of deletions plus insertions in `edits`.
pub fn cost(edits: &[Edit]) -> usize {
    edits
        .iter()
        .filter(|e| !matches!(e, Edit::Keep { .. }))
        .count()
}

/// The one-character tag of a script line.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Tag {
    /// `' '`: keep the next unconsumed line of the old file.
    Keep,
    /// `'-'`: delete the next unconsumed line of the old file.
    Delete,
    /// `'+'`: insert a line.
    Insert,
}

impl Tag {
    /// The byte used for this tag in the textual format.
    pub fn as_byte(self) -> u8 {
        match self {
            Tag::Keep => b' ',
            Tag::Delete => b'-',
            Tag::Insert => b'+',
        }
    }

    /// Parses a tag byte; returns `None` for anything but `' '`, `'-'`, `'+'`.
    pub fn from_byte(b: u8) -> Option<Tag> {
        match b {
            b' ' => Some(Tag::Keep),
            b'-' => Some(Tag::Delete),
            b'+' => Some(Tag::Insert),
            _ => None,
        }
    }
}

/// A script line: a tag and the line content.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ScriptLine<T> {
    /// What to do with the line.
    pub tag: Tag,
    /// The line itself.
    pub text: T,
}
