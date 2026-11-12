//! # btregex
//!
//! A small backtracking regular-expression engine with Perl-style
//! leftmost, greedy, ordered-choice semantics. It reports the first match in
//! a subject together with the position of every capture group.
//!
//! The supported syntax is deliberately compact: literals, `.`, `^`, `$`,
//! character classes (`[a-z]`, `[^0-9_]`), the escapes `\d \D \w \W \s \S`,
//! capturing groups, alternation `|`, and the greedy quantifiers `* + ?
//! {n} {n,} {n,m}` (counts up to [`MAX_REPEAT`]). Matching is over bytes
//! and case-sensitive.
//!
//! The engine is a real backtracker: alternatives are tried left to right,
//! quantifiers take as much as they can and give back one iteration at a
//! time, and the first successful path wins. An optional iteration that
//! matches the empty string ends its repetition. Capture values are those of
//! the successful path; writes made on abandoned paths are undone.
//!
//! # Example
//!
//! ```
//! use btregex::Regex;
//!
//! let re = Regex::new(r"(a|ab)(c|bcd)(d*)").unwrap();
//! let m = re.find("abcd").unwrap();
//! assert_eq!(m.range(), 0..4);
//! assert_eq!(m.group(1), Some(0..1));
//! assert_eq!(m.group(2), Some(1..4));
//! assert_eq!(m.group(3), Some(4..4));
//!
//! // Groups that do not take part in the match are unset.
//! let re = Regex::new(r"x$|^(y)?z").unwrap();
//! assert_eq!(re.find("xz"), None);
//! assert_eq!(re.find("zzz").unwrap().group(1), None);
//! ```
//!
//! # Matching many subjects
//!
//! [`Regex::find`] allocates its working state on every call. To match many
//! subjects against one pattern, create a [`Matcher`] once and reuse it:
//!
//! ```
//! use btregex::Regex;
//!
//! let re = Regex::new(r"\d+").unwrap();
//! let mut matcher = re.matcher();
//! assert_eq!(matcher.find("abc123").unwrap().range(), 3..6);
//! assert!(matcher.find("none").is_none());
//! ```
//!
//! # Modules
//!
//! * [`parser`] turns pattern text into a syntax tree ([`ast`]);
//! * [`analysis`] derives start-position facts from the tree;
//! * [`compiler`] flattens the tree into a backtracking program;
//! * [`matcher`] runs that program with an explicit backtrack stack;
//! * [`batch`] implements the line-oriented batch format used by the CLI.

pub mod analysis;
pub mod ast;
pub mod batch;
pub mod charset;
pub mod compiler;
pub mod error;
pub mod matcher;
pub mod parser;

use std::ops::Range;

pub use error::{Error, ErrorKind};

/// Largest repeat count accepted in `{n}`, `{n,}` and `{n,m}`.
pub const MAX_REPEAT: u32 = 100;

/// Maximum nesting depth of parenthesised groups.
pub const MAX_NESTING: usize = 250;

/// A compiled regular expression.
#[derive(Debug)]
pub struct Regex {
    program: compiler::Program,
    /// Bytes that can begin a match; `None` when a match may be empty (then
    /// every start position must be tried).
    first_bytes: Option<charset::CharSet>,
    /// A match can only start at position 0.
    anchored: bool,
}

/// The result of a successful search.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Match {
    start: usize,
    end: usize,
    groups: Vec<Option<(usize, usize)>>,
}

impl Match {
    /// Offset of the first byte of the match.
    pub fn start(&self) -> usize {
        self.start
    }

    /// Offset one past the last byte of the match.
    pub fn end(&self) -> usize {
        self.end
    }

    /// The matched range.
    pub fn range(&self) -> Range<usize> {
        self.start..self.end
    }

    /// Range captured by group `n` (1-based), or `None` if the group did not
    /// take part in the match or does not exist.
    pub fn group(&self, n: usize) -> Option<Range<usize>> {
        if n == 0 {
            return Some(self.range());
        }
        self.groups
            .get(n - 1)
            .copied()
            .flatten()
            .map(|(s, e)| s..e)
    }

    /// Number of capture groups in the pattern (not counting group 0).
    pub fn group_count(&self) -> usize {
        self.groups.len()
    }

    /// All groups `1..=G` in order, as `(start, end)` pairs.
    pub fn groups(&self) -> &[Option<(usize, usize)>] {
        &self.groups
    }
}

impl Regex {
    /// Compiles `pattern`.
    ///
    /// # Errors
    ///
    /// Returns an [`Error`] if the pattern is not valid in the supported
    /// syntax.
    pub fn new(pattern: &str) -> Result<Regex, Error> {
        Regex::from_bytes(pattern.as_bytes())
    }

    /// Compiles a pattern given as bytes.
    pub fn from_bytes(pattern: &[u8]) -> Result<Regex, Error> {
        let parsed = parser::parse(pattern)?;
        let info = analysis::analyze(&parsed.node);
        let program = compiler::compile(&parsed.node, parsed.group_count)?;
        Ok(Regex {
            program,
            first_bytes: if info.nullable { None } else { Some(info.first) },
            anchored: info.anchored,
        })
    }

    /// Number of capture groups in the pattern.
    pub fn group_count(&self) -> usize {
        self.program.group_count
    }

    /// Creates a reusable matcher for this regex.
    pub fn matcher(&self) -> Matcher<'_> {
        Matcher {
            regex: self,
            machine: matcher::Machine::new(&self.program),
        }
    }

    /// Finds the first match in `subject`.
    pub fn find(&self, subject: &str) -> Option<Match> {
        self.find_bytes(subject.as_bytes())
    }

    /// Finds the first match in a byte string.
    pub fn find_bytes(&self, subject: &[u8]) -> Option<Match> {
        self.matcher().find_bytes(subject)
    }

    /// Whether the regex matches anywhere in `subject`.
    pub fn is_match(&self, subject: &str) -> bool {
        self.find(subject).is_some()
    }
}

/// A [`Regex`] together with reusable scratch memory.
///
/// Searching with a `Matcher` avoids re-allocating the capture table and
/// backtrack stack for every subject.
#[derive(Debug)]
pub struct Matcher<'r> {
    regex: &'r Regex,
    machine: matcher::Machine,
}

impl<'r> Matcher<'r> {
    /// Finds the first match in `subject`.
    pub fn find(&mut self, subject: &str) -> Option<Match> {
        self.find_bytes(subject.as_bytes())
    }

    /// Finds the first match in a byte string.
    ///
    /// Start positions are tried in increasing order; the first start at
    /// which the pattern matches determines the result.
    pub fn find_bytes(&mut self, subject: &[u8]) -> Option<Match> {
        let re = self.regex;
        let len = subject.len();
        let last_start = if re.anchored { 0 } else { len };
        let mut start = 0;
        while start <= last_start {
            if let Some(first) = &re.first_bytes {
                // A non-empty match needs a first byte from the set.
                while start < len && !first.contains(subject[start]) {
                    start += 1;
                }
                if start >= len || start > last_start {
                    return None;
                }
            }
            if let Some(end) = self.machine.run(&re.program, subject, start) {
                let groups = (0..re.program.group_count)
                    .map(|g| self.machine.capture(g))
                    .collect();
                self.machine.reset();
                return Some(Match { start, end, groups });
            }
            start += 1;
        }
        None
    }
}
