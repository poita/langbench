//! # linediff
//!
//! Minimal line-oriented diff and patch.
//!
//! The diff is computed with Myers' O(ND) algorithm in its linear-space,
//! divide-and-conquer ("middle snake") form. The result is always a
//! *shortest* edit script: no heuristics, no cost cut-offs.
//!
//! ## Modules
//!
//! * [`edit`]: the [`Edit`] and [`Tag`] types and [`ScriptLine`].
//! * [`intern`]: maps distinct lines to small integers so that comparing two
//!   lines is O(1).
//! * [`myers`]: the algorithm itself, on integer sequences.
//! * [`diff`]: the convenient entry point for any `Eq + Hash` element type.
//! * [`patch`]: applies an edit script to a sequence.
//! * [`format`]: the textual request/response format used by the CLI.
//! * [`error`]: the error type.
//!
//! ## Example
//!
//! ```
//! use linediff::{cost, diff, patch, Edit, ScriptLine, Tag};
//!
//! let a = ["a", "b", "c", "a", "b", "b", "a"];
//! let b = ["c", "b", "a", "b", "a", "c"];
//! let edits = diff(&a, &b);
//! assert_eq!(cost(&edits), 5); // the minimum
//!
//! // Turn the edits into script lines, then apply them to `a` again.
//! let script: Vec<ScriptLine<&str>> = edits
//!     .iter()
//!     .map(|e| match *e {
//!         Edit::Keep { a: i, .. } => ScriptLine { tag: Tag::Keep, text: a[i] },
//!         Edit::Delete { a: i } => ScriptLine { tag: Tag::Delete, text: a[i] },
//!         Edit::Insert { b: j } => ScriptLine { tag: Tag::Insert, text: b[j] },
//!     })
//!     .collect();
//! assert_eq!(patch(&a, &script).unwrap(), b.to_vec());
//! ```

pub mod diff;
pub mod edit;
pub mod error;
pub mod format;
pub mod intern;
pub mod myers;
pub mod patch;

pub use crate::diff::diff;
pub use crate::edit::{cost, Edit, ScriptLine, Tag};
pub use crate::error::Error;
pub use crate::patch::patch;
