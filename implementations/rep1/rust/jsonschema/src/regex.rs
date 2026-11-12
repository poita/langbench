//! A small ECMA-262 style regular-expression engine for *membership tests*.
//!
//! Supports the subset JSON Schema needs for `pattern` and
//! `patternProperties` (see the crate README): alternation, grouping,
//! greedy/lazy quantifiers (`* + ? {n} {n,} {n,m}`), `.`, `^`, `$`, `\b`,
//! `\B`, character classes and the usual escapes. Matching is over Unicode
//! code points, there are no flags, and [`Regex::is_match`] searches for a
//! match anywhere in the subject.
//!
//! The pattern is compiled to a small NFA program and run with a Thompson
//! simulation, so a test costs O(pattern size × subject length) whatever the
//! pattern looks like — there is no exponential backtracking. Counted
//! repetition is expanded at compile time.

use std::fmt;

/// Upper bound on compiled program size, to keep pathological counted
/// repetitions from exhausting memory.
const MAX_PROGRAM: usize = 4_000_000;

/// A pattern that could not be compiled.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RegexError {
    /// What is wrong with the pattern.
    pub message: String,
}

impl fmt::Display for RegexError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "invalid regular expression: {}", self.message)
    }
}

impl std::error::Error for RegexError {}

fn err<T>(message: &str) -> Result<T, RegexError> {
    Err(RegexError {
        message: message.to_string(),
    })
}

// ---------------------------------------------------------------------------
// Character sets
// ---------------------------------------------------------------------------

const MAX_CP: u32 = 0x10FFFF;

/// A set of code points stored as sorted, non-overlapping inclusive ranges.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
struct CharSet {
    ranges: Vec<(u32, u32)>,
}

impl CharSet {
    fn from_ranges(mut ranges: Vec<(u32, u32)>) -> CharSet {
        ranges.sort_unstable();
        let mut merged: Vec<(u32, u32)> = Vec::with_capacity(ranges.len());
        for (lo, hi) in ranges {
            match merged.last_mut() {
                Some(last) if lo <= last.1.saturating_add(1) => last.1 = last.1.max(hi),
                _ => merged.push((lo, hi)),
            }
        }
        CharSet { ranges: merged }
    }

    fn negated(&self) -> CharSet {
        let mut out = Vec::new();
        let mut next = 0u32;
        for &(lo, hi) in &self.ranges {
            if lo > next {
                out.push((next, lo - 1));
            }
            next = hi.saturating_add(1);
        }
        if next <= MAX_CP {
            out.push((next, MAX_CP));
        }
        CharSet { ranges: out }
    }

    fn contains(&self, c: u32) -> bool {
        self.ranges
            .binary_search_by(|&(lo, hi)| {
                if c < lo {
                    std::cmp::Ordering::Greater
                } else if c > hi {
                    std::cmp::Ordering::Less
                } else {
                    std::cmp::Ordering::Equal
                }
            })
            .is_ok()
    }
}

fn digit_ranges() -> Vec<(u32, u32)> {
    vec![(0x30, 0x39)]
}

fn word_ranges() -> Vec<(u32, u32)> {
    vec![(0x30, 0x39), (0x41, 0x5A), (0x5F, 0x5F), (0x61, 0x7A)]
}

fn space_ranges() -> Vec<(u32, u32)> {
    vec![
        (0x09, 0x0D),
        (0x20, 0x20),
        (0xA0, 0xA0),
        (0x1680, 0x1680),
        (0x2000, 0x200A),
        (0x2028, 0x2029),
        (0x202F, 0x202F),
        (0x205F, 0x205F),
        (0x3000, 0x3000),
        (0xFEFF, 0xFEFF),
    ]
}

fn is_word(c: Option<char>) -> bool {
    matches!(c, Some('0'..='9' | 'A'..='Z' | 'a'..='z' | '_'))
}

// ---------------------------------------------------------------------------
// Syntax tree and parser
// ---------------------------------------------------------------------------

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Assertion {
    Start,
    End,
    WordBoundary,
    NotWordBoundary,
}

#[derive(Clone, Debug)]
enum Ast {
    Empty,
    /// A literal code point (may be a lone surrogate, which never matches).
    Char(u32),
    Any,
    Class(CharSet),
    Assert(Assertion),
    Concat(Vec<Ast>),
    Alt(Vec<Ast>),
    Repeat { node: Box<Ast>, min: u32, max: Option<u32> },
}

struct Parser {
    chars: Vec<char>,
    pos: usize,
}

/// One item of a character class: a single code point or a set (from a
/// class escape such as `\d`).
enum ClassAtom {
    Char(u32),
    Set(Vec<(u32, u32)>),
}

impl Parser {
    fn peek(&self) -> Option<char> {
        self.chars.get(self.pos).copied()
    }

    fn eat(&mut self, c: char) -> bool {
        if self.peek() == Some(c) {
            self.pos += 1;
            true
        } else {
            false
        }
    }

    fn alternation(&mut self) -> Result<Ast, RegexError> {
        let mut branches = vec![self.concat()?];
        while self.eat('|') {
            branches.push(self.concat()?);
        }
        Ok(if branches.len() == 1 {
            branches.pop().unwrap()
        } else {
            Ast::Alt(branches)
        })
    }

    fn concat(&mut self) -> Result<Ast, RegexError> {
        let mut items = Vec::new();
        while let Some(c) = self.peek() {
            if c == '|' || c == ')' {
                break;
            }
            let atom = self.atom()?;
            items.push(self.quantified(atom)?);
        }
        Ok(match items.len() {
            0 => Ast::Empty,
            1 => items.pop().unwrap(),
            _ => Ast::Concat(items),
        })
    }

    fn atom(&mut self) -> Result<Ast, RegexError> {
        let c = self.peek().expect("caller checked");
        self.pos += 1;
        Ok(match c {
            '(' => {
                if self.eat('?') {
                    if !self.eat(':') {
                        return err("only (?: ... ) groups are supported");
                    }
                }
                let inner = self.alternation()?;
                if !self.eat(')') {
                    return err("unterminated group");
                }
                inner
            }
            '[' => self.class()?,
            '.' => Ast::Any,
            '^' => Ast::Assert(Assertion::Start),
            '$' => Ast::Assert(Assertion::End),
            '\\' => self.escape_outside_class()?,
            '*' | '+' | '?' => return err("nothing to repeat"),
            c => Ast::Char(c as u32),
        })
    }

    /// Parses `{n}`, `{n,}` or `{n,m}` at the current position (which holds
    /// `{`). Returns `None`, consuming nothing, when it is not a
    /// well-formed quantifier.
    fn braces(&mut self) -> Result<Option<(u32, Option<u32>)>, RegexError> {
        let save = self.pos;
        self.pos += 1;
        let num = |p: &mut Parser| -> Option<u32> {
            let start = p.pos;
            let mut v: u32 = 0;
            while let Some(d) = p.peek().and_then(|c| c.to_digit(10)) {
                v = v.saturating_mul(10).saturating_add(d);
                p.pos += 1;
            }
            (p.pos > start).then_some(v)
        };
        let result = (|| {
            let min = num(self)?;
            if self.eat('}') {
                return Some((min, Some(min)));
            }
            if !self.eat(',') {
                return None;
            }
            if self.eat('}') {
                return Some((min, None));
            }
            let max = num(self)?;
            self.eat('}').then_some((min, Some(max)))
        })();
        match result {
            Some((min, Some(max))) if min > max => err("numbers out of order in {} quantifier"),
            Some(q) => Ok(Some(q)),
            None => {
                self.pos = save;
                Ok(None)
            }
        }
    }

    fn quantified(&mut self, atom: Ast) -> Result<Ast, RegexError> {
        let (min, max) = match self.peek() {
            Some('*') => {
                self.pos += 1;
                (0, None)
            }
            Some('+') => {
                self.pos += 1;
                (1, None)
            }
            Some('?') => {
                self.pos += 1;
                (0, Some(1))
            }
            Some('{') => match self.braces()? {
                Some(q) => q,
                None => return Ok(atom),
            },
            _ => return Ok(atom),
        };
        // Laziness does not change whether a match exists.
        self.eat('?');
        if matches!(self.peek(), Some('*' | '+' | '?')) {
            return err("nothing to repeat");
        }
        Ok(Ast::Repeat {
            node: Box::new(atom),
            min,
            max,
        })
    }

    fn hex_digits(&mut self, n: usize) -> Option<u32> {
        if self.pos + n > self.chars.len() {
            return None;
        }
        let mut v = 0u32;
        for i in 0..n {
            v = v * 16 + self.chars[self.pos + i].to_digit(16)?;
        }
        self.pos += n;
        Some(v)
    }

    /// Parses the escape after a `\` that is common to classes and the
    /// top level. `c` is the escaped character, already consumed.
    fn common_escape(&mut self, c: char) -> ClassAtom {
        match c {
            'd' => ClassAtom::Set(digit_ranges()),
            'D' => ClassAtom::Set(CharSet::from_ranges(digit_ranges()).negated().ranges),
            'w' => ClassAtom::Set(word_ranges()),
            'W' => ClassAtom::Set(CharSet::from_ranges(word_ranges()).negated().ranges),
            's' => ClassAtom::Set(space_ranges()),
            'S' => ClassAtom::Set(CharSet::from_ranges(space_ranges()).negated().ranges),
            'n' => ClassAtom::Char(0x0A),
            'r' => ClassAtom::Char(0x0D),
            't' => ClassAtom::Char(0x09),
            'f' => ClassAtom::Char(0x0C),
            'v' => ClassAtom::Char(0x0B),
            '0' => ClassAtom::Char(0),
            'x' => match self.hex_digits(2) {
                Some(v) => ClassAtom::Char(v),
                None => ClassAtom::Char('x' as u32),
            },
            'u' => {
                let save = self.pos;
                match self.hex_digits(4) {
                    Some(hi) if (0xD800..0xDC00).contains(&hi) => {
                        // Possibly the first half of a surrogate pair.
                        let after_hi = self.pos;
                        if self.eat('\\') && self.eat('u') {
                            if let Some(lo) = self.hex_digits(4) {
                                if (0xDC00..0xE000).contains(&lo) {
                                    return ClassAtom::Char(
                                        0x10000 + ((hi - 0xD800) << 10) + (lo - 0xDC00),
                                    );
                                }
                            }
                        }
                        self.pos = after_hi;
                        ClassAtom::Char(hi)
                    }
                    Some(v) => ClassAtom::Char(v),
                    None => {
                        self.pos = save;
                        ClassAtom::Char('u' as u32)
                    }
                }
            }
            'c' => match self.peek() {
                Some(l) if l.is_ascii_alphabetic() => {
                    self.pos += 1;
                    ClassAtom::Char(l as u32 % 32)
                }
                // Annex B: a stray `\c` stands for a literal backslash.
                _ => {
                    self.pos -= 1;
                    ClassAtom::Char('\\' as u32)
                }
            },
            // Any other escaped character stands for itself.
            c => ClassAtom::Char(c as u32),
        }
    }

    fn escape_outside_class(&mut self) -> Result<Ast, RegexError> {
        let Some(c) = self.peek() else {
            return err("pattern ends with a backslash");
        };
        self.pos += 1;
        Ok(match c {
            'b' => Ast::Assert(Assertion::WordBoundary),
            'B' => Ast::Assert(Assertion::NotWordBoundary),
            _ => match self.common_escape(c) {
                ClassAtom::Char(v) => Ast::Char(v),
                ClassAtom::Set(r) => Ast::Class(CharSet::from_ranges(r)),
            },
        })
    }

    fn class_atom(&mut self) -> Result<ClassAtom, RegexError> {
        let Some(c) = self.peek() else {
            return err("unterminated character class");
        };
        self.pos += 1;
        if c != '\\' {
            return Ok(ClassAtom::Char(c as u32));
        }
        let Some(e) = self.peek() else {
            return err("pattern ends with a backslash");
        };
        self.pos += 1;
        if e == 'b' {
            return Ok(ClassAtom::Char(0x08));
        }
        if e == '-' {
            return Ok(ClassAtom::Char('-' as u32));
        }
        Ok(self.common_escape(e))
    }

    fn class(&mut self) -> Result<Ast, RegexError> {
        let negate = self.eat('^');
        let mut ranges: Vec<(u32, u32)> = Vec::new();
        loop {
            match self.peek() {
                None => return err("unterminated character class"),
                Some(']') => {
                    self.pos += 1;
                    break;
                }
                _ => {}
            }
            let lo = self.class_atom()?;
            // A `-` forms a range unless it is last in the class.
            if self.peek() == Some('-') && self.chars.get(self.pos + 1).is_some_and(|&c| c != ']') {
                let save = self.pos;
                self.pos += 1;
                let hi = self.class_atom()?;
                match (&lo, &hi) {
                    (ClassAtom::Char(a), ClassAtom::Char(b)) => {
                        if a > b {
                            return err("range out of order in character class");
                        }
                        ranges.push((*a, *b));
                        continue;
                    }
                    _ => {
                        // Annex B: `\d-x` means `\d`, `-`, `x`.
                        self.pos = save;
                    }
                }
            }
            match lo {
                ClassAtom::Char(a) => ranges.push((a, a)),
                ClassAtom::Set(r) => ranges.extend(r),
            }
        }
        let set = CharSet::from_ranges(ranges);
        Ok(Ast::Class(if negate { set.negated() } else { set }))
    }
}

// ---------------------------------------------------------------------------
// Program
// ---------------------------------------------------------------------------

#[derive(Clone, Debug)]
enum Inst {
    Char(u32),
    Any,
    Class(usize),
    Split(usize, usize),
    Jmp(usize),
    Assert(Assertion),
    Match,
}

struct Compiler {
    prog: Vec<Inst>,
    classes: Vec<CharSet>,
}

impl Compiler {
    fn push(&mut self, i: Inst) -> Result<usize, RegexError> {
        if self.prog.len() >= MAX_PROGRAM {
            return err("pattern is too large");
        }
        self.prog.push(i);
        Ok(self.prog.len() - 1)
    }

    fn emit(&mut self, ast: &Ast) -> Result<(), RegexError> {
        match ast {
            Ast::Empty => {}
            Ast::Char(c) => {
                self.push(Inst::Char(*c))?;
            }
            Ast::Any => {
                self.push(Inst::Any)?;
            }
            Ast::Class(set) => {
                self.classes.push(set.clone());
                let idx = self.classes.len() - 1;
                self.push(Inst::Class(idx))?;
            }
            Ast::Assert(a) => {
                self.push(Inst::Assert(*a))?;
            }
            Ast::Concat(items) => {
                for i in items {
                    self.emit(i)?;
                }
            }
            Ast::Alt(branches) => {
                let mut jumps = Vec::new();
                for (n, b) in branches.iter().enumerate() {
                    if n + 1 < branches.len() {
                        let split = self.push(Inst::Split(0, 0))?;
                        self.emit(b)?;
                        jumps.push(self.push(Inst::Jmp(0))?);
                        let next = self.prog.len();
                        self.prog[split] = Inst::Split(split + 1, next);
                    } else {
                        self.emit(b)?;
                    }
                }
                let end = self.prog.len();
                for j in jumps {
                    self.prog[j] = Inst::Jmp(end);
                }
            }
            Ast::Repeat { node, min, max } => {
                for _ in 0..*min {
                    self.emit(node)?;
                }
                match max {
                    None => {
                        // x*
                        let split = self.push(Inst::Split(0, 0))?;
                        self.emit(node)?;
                        self.push(Inst::Jmp(split))?;
                        let end = self.prog.len();
                        self.prog[split] = Inst::Split(split + 1, end);
                    }
                    Some(max) => {
                        // (max - min) nested optional copies.
                        let mut splits = Vec::new();
                        for _ in *min..*max {
                            splits.push(self.push(Inst::Split(0, 0))?);
                            self.emit(node)?;
                        }
                        let end = self.prog.len();
                        for s in splits {
                            self.prog[s] = Inst::Split(s + 1, end);
                        }
                    }
                }
            }
        }
        Ok(())
    }
}

/// A sparse set of program counters, cleared in O(1).
struct PcSet {
    dense: Vec<usize>,
    sparse: Vec<usize>,
}

impl PcSet {
    fn new(n: usize) -> Self {
        PcSet {
            dense: Vec::with_capacity(n),
            sparse: vec![0; n],
        }
    }

    fn contains(&self, pc: usize) -> bool {
        let s = self.sparse[pc];
        s < self.dense.len() && self.dense[s] == pc
    }

    fn insert(&mut self, pc: usize) {
        self.sparse[pc] = self.dense.len();
        self.dense.push(pc);
    }

    fn clear(&mut self) {
        self.dense.clear();
    }
}

/// A compiled regular expression.
///
/// ```
/// use jsonschema::regex::Regex;
/// let re = Regex::new(r"^a+b$").unwrap();
/// assert!(re.is_match("aaab"));
/// assert!(!re.is_match("aaabc"));
/// assert!(Regex::new("bar").unwrap().is_match("foobarbaz"));
/// ```
#[derive(Clone, Debug)]
pub struct Regex {
    prog: Vec<Inst>,
    classes: Vec<CharSet>,
}

impl Regex {
    /// Compiles a pattern.
    pub fn new(pattern: &str) -> Result<Regex, RegexError> {
        let mut p = Parser {
            chars: pattern.chars().collect(),
            pos: 0,
        };
        let ast = p.alternation()?;
        if p.pos < p.chars.len() {
            return err("unmatched ')'");
        }
        let mut c = Compiler {
            prog: Vec::new(),
            classes: Vec::new(),
        };
        c.emit(&ast)?;
        c.push(Inst::Match)?;
        Ok(Regex {
            prog: c.prog,
            classes: c.classes,
        })
    }

    /// Returns `true` if the pattern matches anywhere in `text`.
    pub fn is_match(&self, text: &str) -> bool {
        let chars: Vec<char> = text.chars().collect();
        let n = self.prog.len();
        let mut clist = PcSet::new(n);
        let mut nlist = PcSet::new(n);
        let mut stack: Vec<usize> = Vec::new();
        for i in 0..=chars.len() {
            // Start a new attempt at this position.
            self.add_thread(&mut clist, &mut stack, 0, &chars, i);
            let cur = chars.get(i).map(|&c| c as u32);
            nlist.clear();
            for k in 0..clist.dense.len() {
                let pc = clist.dense[k];
                let ok = match &self.prog[pc] {
                    Inst::Match => return true,
                    Inst::Char(c) => cur == Some(*c),
                    Inst::Any => cur.is_some_and(|c| !matches!(c, 0x0A | 0x0D | 0x2028 | 0x2029)),
                    Inst::Class(idx) => cur.is_some_and(|c| self.classes[*idx].contains(c)),
                    _ => false,
                };
                if ok {
                    self.add_thread(&mut nlist, &mut stack, pc + 1, &chars, i + 1);
                }
            }
            std::mem::swap(&mut clist, &mut nlist);
        }
        false
    }

    /// Adds `pc` and everything reachable through empty transitions at text
    /// position `at`.
    fn add_thread(&self, set: &mut PcSet, stack: &mut Vec<usize>, pc: usize, chars: &[char], at: usize) {
        stack.push(pc);
        while let Some(pc) = stack.pop() {
            if set.contains(pc) {
                continue;
            }
            set.insert(pc);
            match &self.prog[pc] {
                Inst::Jmp(t) => stack.push(*t),
                Inst::Split(a, b) => {
                    stack.push(*b);
                    stack.push(*a);
                }
                Inst::Assert(a) => {
                    let prev = at.checked_sub(1).map(|i| chars[i]);
                    let next = chars.get(at).copied();
                    let holds = match a {
                        Assertion::Start => at == 0,
                        Assertion::End => at == chars.len(),
                        Assertion::WordBoundary => is_word(prev) != is_word(next),
                        Assertion::NotWordBoundary => is_word(prev) == is_word(next),
                    };
                    if holds {
                        stack.push(pc + 1);
                    }
                }
                _ => {}
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn m(p: &str, s: &str) -> bool {
        Regex::new(p).unwrap_or_else(|e| panic!("{p}: {e}")).is_match(s)
    }

    #[test]
    fn literals_and_search() {
        assert!(m("bar", "foobarbaz"));
        assert!(!m("bar", "foobaz"));
        assert!(m("", "anything"));
        assert!(m("", ""));
    }

    #[test]
    fn anchors() {
        assert!(m("^a$", "a"));
        assert!(!m("^a$", "a\n"));
        assert!(!m("^a$", "ba"));
        assert!(m("^$", ""));
        assert!(!m("^$", "x"));
        assert!(m("a|^b", "xb") == false);
        assert!(m("a|^b", "bx"));
    }

    #[test]
    fn word_boundaries_are_ascii() {
        assert!(m(r"\bcat\b", "écat "));
        assert!(m(r"\bcat\b", "a cat."));
        assert!(!m(r"\bcat\b", "concatenate"));
        assert!(m(r"\Bcat", "concat"));
        assert!(!m(r"\b", ""));
    }

    #[test]
    fn quantifiers() {
        assert!(m("^a{3}$", "aaa"));
        assert!(!m("^a{3}$", "aa"));
        assert!(m("^a{2,}$", "aaaa"));
        assert!(m("^a{2,3}$", "aaa"));
        assert!(!m("^a{2,3}$", "aaaa"));
        assert!(m("^(ab)*c$", "ababc"));
        assert!(m("^a+?$", "aaa"));
        assert!(m("^colou?r$", "color"));
        assert!(m("^a{0}b$", "b"));
    }

    #[test]
    fn braces_that_are_not_quantifiers_are_literal() {
        assert!(m("a{", "a{"));
        assert!(m("a{x}", "a{x}"));
        assert!(m("a{,3}", "a{,3}"));
        assert!(m("^{}$", "{}"));
        assert!(m("^a}$", "a}"));
    }

    #[test]
    fn classes() {
        assert!(m("^[a-c]+$", "abcabc"));
        assert!(!m("^[a-c]+$", "abd"));
        assert!(m("^[^a-c]$", "d"));
        assert!(m("^[^a-c]$", "\n"));
        assert!(m("^[-a]$", "-"));
        assert!(m("^[a-]$", "-"));
        assert!(m(r"^[\-a]$", "-"));
        assert!(m(r"^[\d.]+$", "3.14"));
        assert!(m(r"^[\w-]+$", "a-b_c"));
        assert!(m(r"^[\D]$", "x"));
        assert!(m(r"^[^\s]+$", "abc"));
        assert!(m(r"^[\b]$", "\u{8}"));
        assert!(m("^[]]$", "]") == false);
        assert!(m("^[^]$", "x"));
        assert!(m(r"^[\]]$", "]"));
    }

    #[test]
    fn dot_excludes_line_terminators() {
        assert!(m("^.$", "x"));
        assert!(m("^.$", "💩"));
        for t in ["\n", "\r", "\u{2028}", "\u{2029}"] {
            assert!(!m("^.$", t));
        }
    }

    #[test]
    fn class_escapes() {
        assert!(m(r"^\d+$", "0123"));
        assert!(!m(r"^\d+$", "٣"));
        assert!(m(r"^\w+$", "aZ_09"));
        assert!(!m(r"^\w+$", "é"));
        assert!(m(r"^\s+$", " \t\n\u{a0}\u{3000}\u{feff}"));
        assert!(m(r"^\S+$", "abc"));
        assert!(m(r"^\W$", "-"));
    }

    #[test]
    fn character_escapes() {
        assert!(m(r"^\n\r\t\f\v\0$", "\n\r\t\u{c}\u{b}\0"));
        assert!(m(r"^\x41$", "A"));
        assert!(m(r"^A$", "A"));
        assert!(m(r"^💩$", "💩"));
        assert!(m(r"^\cJ$", "\n"));
        assert!(m(r"^\.\\\*\[\/\-$", ".\\*[/-"));
    }

    #[test]
    fn unicode_is_by_code_point() {
        assert!(m("^.{1}$", "💩"));
        assert!(m("^.{2}$", "e\u{301}"));
        assert!(m("^[💩]$", "💩"));
        assert!(m("^[\u{80}-\u{10ffff}]$", "💩"));
    }

    #[test]
    fn alternation_and_groups() {
        assert!(m("^(a|b)c$", "bc"));
        assert!(m("^(?:foo|bar)+$", "foobarfoo"));
        assert!(m("^(|a)$", ""));
        assert!(m("a|", "zzz"));
    }

    #[test]
    fn no_exponential_blowup() {
        let re = Regex::new("^(a*)*$").unwrap();
        assert!(!re.is_match(&format!("{}b", "a".repeat(5000))));
        let re = Regex::new("^(a|aa)+$").unwrap();
        assert!(!re.is_match(&format!("{}b", "a".repeat(5000))));
        let re = Regex::new("(x+x+)+y").unwrap();
        assert!(!re.is_match(&"x".repeat(5000)));
    }

    #[test]
    fn counted_repetition_expands() {
        assert!(m("^(a{2}){3}$", "aaaaaa"));
        assert!(!m("^(a{2}){3}$", "aaaaa"));
        assert!(m("^a{100}$", &"a".repeat(100)));
    }

    #[test]
    fn rejects_bad_patterns() {
        for p in ["(", ")", "[", "*a", "a**", r"\", "(?=a)", "[z-a]", "a{3,1}"] {
            assert!(Regex::new(p).is_err(), "{p}");
        }
    }
}
