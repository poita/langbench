//! # btregex
//!
//! A small backtracking regular-expression engine with Perl-style
//! *leftmost, greedy, ordered-choice* semantics that reports the exact
//! position of every capture group.
//!
//! ```
//! use btregex::Regex;
//!
//! let re = Regex::new(r"(a|ab)(c|bcd)(d*)").unwrap();
//! let m = re.find("abcd").unwrap();
//! assert_eq!((m.start(), m.end()), (0, 4));
//! assert_eq!(m.get(1), Some((0, 1)));
//! assert_eq!(m.get(2), Some((1, 4)));
//! assert_eq!(m.get(3), Some((4, 4)));
//! ```
//!
//! ## Syntax
//!
//! ```text
//! regex      := branch ( '|' branch )*
//! branch     := piece*
//! piece      := atom quantifier?
//! atom       := literal | '.' | '^' | '$' | class | escape | '(' regex ')'
//! quantifier := '*' | '+' | '?' | '{n}' | '{n,}' | '{n,m}'
//! ```
//!
//! * `.` matches any single byte; `^` / `$` match only at the very start /
//!   end of the subject (they may appear anywhere and take no quantifier).
//! * Escapes: `\d \w \s` and their complements `\D \W \S`; a backslash before
//!   any other non-alphanumeric character matches it literally.
//! * Classes: `[abc]`, `[^a-z]`, `[\d_-]`; ranges `x-y`; a `-` first, last or
//!   escaped is literal.
//! * Groups `( ... )` always capture and are numbered by their opening
//!   parenthesis. There are no non-capturing groups, lazy quantifiers,
//!   backreferences or lookaround.
//! * Counted quantifier bounds are limited to
//!   [`parser::MAX_REPEAT`](parser::MAX_REPEAT).
//!
//! ## Semantics
//!
//! Matching follows the classic backtracking definition: alternatives are
//! tried left to right, quantifiers are greedy and give back one iteration at
//! a time, and start offsets `0..=len` are tried in order; the first
//! successful start is the reported match. An optional iteration that
//! consumes nothing ends its repetition. A group's capture is the text it
//! matched the last time it completed on the successful path; captures set on
//! abandoned paths are discarded.
//!
//! Subjects and patterns are handled as bytes. Character classes and
//! escapes are meant for ASCII; non-ASCII bytes are matched individually.
//!
//! The engine is exponential in the worst case, like any backtracking
//! matcher, but uses an explicit stack, so deep backtracking (`.*` over a
//! very long subject) cannot overflow the call stack.
//!
//! ## Reusing buffers
//!
//! [`Regex::find`] allocates per call. When matching many subjects, use
//! [`Regex::search`] with a reusable [`Scratch`]:
//!
//! ```
//! use btregex::{Regex, Scratch};
//!
//! let re = Regex::new(r"(\d+)-(\d+)").unwrap();
//! let mut scratch = Scratch::new();
//! for subject in ["10-20", "none", "x 3-4 y"] {
//!     if re.search(subject.as_bytes(), &mut scratch) {
//!         println!("{:?} {:?}", scratch.range(), scratch.group(1));
//!     }
//! }
//! ```

pub mod analysis;
pub mod ast;
pub mod batch;
pub mod charset;
pub mod compile;
pub mod error;
pub mod parser;
mod vm;

pub use error::Error;

use charset::ByteSet;
use compile::Program;

/// A compiled regular expression.
#[derive(Clone, Debug)]
pub struct Regex {
    prog: Program,
    /// Bytes that can begin a match; `None` if the pattern can match empty
    /// (or the set is not useful), in which case no start is skipped.
    first: Option<ByteSet>,
    /// Every match must start at offset 0.
    anchored: bool,
}

/// Reusable working memory for [`Regex::search`].
#[derive(Debug, Default)]
pub struct Scratch {
    regs: Vec<usize>,
    stack: Vec<vm::Entry>,
    groups: usize,
    start: usize,
    end: usize,
}

impl Scratch {
    /// Creates empty scratch space.
    pub fn new() -> Self {
        Self::default()
    }

    /// Start offset of the last successful search.
    pub fn start(&self) -> usize {
        self.start
    }

    /// End offset (exclusive) of the last successful search.
    pub fn end(&self) -> usize {
        self.end
    }

    /// `start()..end()` of the last successful search.
    pub fn range(&self) -> (usize, usize) {
        (self.start, self.end)
    }

    /// Number of capture groups of the regex last searched with.
    pub fn group_count(&self) -> usize {
        self.groups
    }

    /// The span of capture group `g` (1-based) after a successful search, or
    /// `None` if the group did not participate (or `g` is out of range).
    pub fn group(&self, g: usize) -> Option<(usize, usize)> {
        if g == 0 || g > self.groups {
            return None;
        }
        let s = self.regs[2 * (g - 1)];
        if s == vm::UNSET {
            None
        } else {
            Some((s, self.regs[2 * (g - 1) + 1]))
        }
    }
}

/// The first match of a regex in a subject, with all capture positions.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Match {
    start: usize,
    end: usize,
    groups: Vec<Option<(usize, usize)>>,
}

impl Match {
    /// Start offset of the whole match.
    pub fn start(&self) -> usize {
        self.start
    }

    /// End offset (exclusive) of the whole match.
    pub fn end(&self) -> usize {
        self.end
    }

    /// Span of group `i`; group 0 is the whole match. `None` if the group is
    /// unset or `i` is out of range.
    pub fn get(&self, i: usize) -> Option<(usize, usize)> {
        if i == 0 {
            Some((self.start, self.end))
        } else {
            self.groups.get(i - 1).copied().flatten()
        }
    }

    /// Number of capture groups in the regex (not counting group 0).
    pub fn group_count(&self) -> usize {
        self.groups.len()
    }
}

impl Regex {
    /// Compiles `pattern`.
    pub fn new(pattern: &str) -> Result<Regex, Error> {
        Regex::from_bytes(pattern.as_bytes())
    }

    /// Compiles a pattern given as bytes.
    pub fn from_bytes(pattern: &[u8]) -> Result<Regex, Error> {
        let parsed = parser::parse(pattern)?;
        let prog = compile::compile(&parsed.node, parsed.group_count)?;
        let mut set = ByteSet::new();
        let nullable = analysis::first_bytes(&parsed.node, &mut set);
        Ok(Regex {
            prog,
            first: if nullable { None } else { Some(set) },
            anchored: analysis::anchored_at_start(&parsed.node),
        })
    }

    /// Number of capture groups.
    pub fn group_count(&self) -> usize {
        self.prog.groups
    }

    /// Finds the first match in `subject`.
    pub fn find(&self, subject: &str) -> Option<Match> {
        self.find_bytes(subject.as_bytes())
    }

    /// Finds the first match in a byte string.
    pub fn find_bytes(&self, subject: &[u8]) -> Option<Match> {
        let mut scratch = Scratch::new();
        if !self.search(subject, &mut scratch) {
            return None;
        }
        Some(Match {
            start: scratch.start,
            end: scratch.end,
            groups: (1..=self.prog.groups).map(|g| scratch.group(g)).collect(),
        })
    }

    /// Returns true if the regex matches somewhere in `subject`.
    pub fn is_match(&self, subject: &str) -> bool {
        self.search(subject.as_bytes(), &mut Scratch::new())
    }

    /// Searches `subject` for the first match, leaving the result in
    /// `scratch` (see [`Scratch::range`] and [`Scratch::group`]). Returns
    /// whether a match was found. Allocation-free once `scratch` has grown.
    pub fn search(&self, subject: &[u8], scratch: &mut Scratch) -> bool {
        let prog = &self.prog;
        scratch.groups = prog.groups;
        scratch.regs.clear();
        scratch.regs.resize(prog.nregs, vm::UNSET);
        scratch.stack.clear();
        let last = if self.anchored { 0 } else { subject.len() };
        for start in 0..=last {
            if let Some(first) = &self.first {
                if start >= subject.len() || !first.contains(subject[start]) {
                    continue;
                }
            }
            if let Some(end) = vm::run(prog, subject, start, &mut scratch.regs, &mut scratch.stack)
            {
                scratch.start = start;
                scratch.end = end;
                scratch.stack.clear();
                return true;
            }
        }
        false
    }
}
