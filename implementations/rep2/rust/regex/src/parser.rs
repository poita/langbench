//! Recursive-descent parser: pattern text to [`Node`] tree.

use crate::ast::Node;
use crate::charset::CharSet;
use crate::error::{Error, ErrorKind};
use crate::{MAX_NESTING, MAX_REPEAT};

/// Result of parsing a whole pattern.
#[derive(Debug)]
pub struct Parsed {
    /// The root of the syntax tree.
    pub node: Node,
    /// Number of capturing groups in the pattern.
    pub group_count: usize,
}

/// Parses `pattern` into a syntax tree.
pub fn parse(pattern: &[u8]) -> Result<Parsed, Error> {
    let mut p = Parser {
        src: pattern,
        pos: 0,
        groups: 0,
        depth: 0,
    };
    let node = p.regex()?;
    if p.pos < p.src.len() {
        // regex() only stops early at a `)`.
        return Err(p.err(ErrorKind::UnmatchedCloseParen));
    }
    Ok(Parsed {
        node,
        group_count: p.groups,
    })
}

struct Parser<'a> {
    src: &'a [u8],
    pos: usize,
    groups: usize,
    depth: usize,
}

fn is_quantifier_start(b: u8) -> bool {
    matches!(b, b'*' | b'+' | b'?' | b'{')
}

impl<'a> Parser<'a> {
    fn err(&self, kind: ErrorKind) -> Error {
        Error::new(kind, self.pos)
    }

    fn peek(&self) -> Option<u8> {
        self.src.get(self.pos).copied()
    }

    fn peek_at(&self, off: usize) -> Option<u8> {
        self.src.get(self.pos + off).copied()
    }

    /// regex := branch ( '|' branch )*
    fn regex(&mut self) -> Result<Node, Error> {
        let mut branches = vec![self.branch()?];
        while self.peek() == Some(b'|') {
            self.pos += 1;
            branches.push(self.branch()?);
        }
        Ok(if branches.len() == 1 {
            branches.pop().unwrap()
        } else {
            Node::Alt(branches)
        })
    }

    /// branch := piece*
    fn branch(&mut self) -> Result<Node, Error> {
        let mut items = Vec::new();
        while let Some(b) = self.peek() {
            if b == b'|' || b == b')' {
                break;
            }
            items.push(self.piece()?);
        }
        Ok(match items.len() {
            0 => Node::Empty,
            1 => items.pop().unwrap(),
            _ => Node::Concat(items),
        })
    }

    /// piece := atom quantifier?
    fn piece(&mut self) -> Result<Node, Error> {
        let atom = self.atom()?;
        let Some(b) = self.peek() else {
            return Ok(atom);
        };
        if !is_quantifier_start(b) {
            return Ok(atom);
        }
        if matches!(atom, Node::Bol | Node::Eol) {
            return Err(self.err(ErrorKind::QuantifierOnAnchor));
        }
        let (min, max) = self.quantifier()?;
        if let Some(b) = self.peek() {
            if is_quantifier_start(b) {
                return Err(self.err(ErrorKind::RepeatedQuantifier));
            }
        }
        Ok(Node::Repeat {
            node: Box::new(atom),
            min,
            max,
        })
    }

    fn quantifier(&mut self) -> Result<(u32, Option<u32>), Error> {
        let b = self.peek().unwrap();
        self.pos += 1;
        match b {
            b'*' => Ok((0, None)),
            b'+' => Ok((1, None)),
            b'?' => Ok((0, Some(1))),
            _ => {
                let n = self.number()?;
                let result = match self.peek() {
                    Some(b'}') => (n, Some(n)),
                    Some(b',') => {
                        self.pos += 1;
                        if self.peek() == Some(b'}') {
                            (n, None)
                        } else {
                            let m = self.number()?;
                            if m < n {
                                return Err(self.err(ErrorKind::InvalidQuantifier));
                            }
                            (n, Some(m))
                        }
                    }
                    _ => return Err(self.err(ErrorKind::InvalidQuantifier)),
                };
                if self.peek() != Some(b'}') {
                    return Err(self.err(ErrorKind::InvalidQuantifier));
                }
                self.pos += 1;
                Ok(result)
            }
        }
    }

    /// A plain decimal integer without leading zeros, at most `MAX_REPEAT`.
    fn number(&mut self) -> Result<u32, Error> {
        let start = self.pos;
        let mut value: u32 = 0;
        while let Some(b) = self.peek() {
            if !b.is_ascii_digit() {
                break;
            }
            value = value * 10 + (b - b'0') as u32;
            self.pos += 1;
            if value > MAX_REPEAT {
                return Err(self.err(ErrorKind::RepeatTooLarge));
            }
        }
        let len = self.pos - start;
        if len == 0 || (len > 1 && self.src[start] == b'0') {
            return Err(Error::new(ErrorKind::InvalidQuantifier, start));
        }
        Ok(value)
    }

    fn atom(&mut self) -> Result<Node, Error> {
        let b = self.peek().unwrap();
        match b {
            b'(' => self.group(),
            b'[' => self.class(),
            b'\\' => self.escape(),
            b'.' => {
                self.pos += 1;
                Ok(Node::Any)
            }
            b'^' => {
                self.pos += 1;
                Ok(Node::Bol)
            }
            b'$' => {
                self.pos += 1;
                Ok(Node::Eol)
            }
            b'*' | b'+' | b'?' | b'{' => Err(self.err(ErrorKind::DanglingQuantifier)),
            b']' | b'}' => Err(self.err(ErrorKind::UnexpectedMeta)),
            _ => {
                self.pos += 1;
                Ok(Node::Char(b))
            }
        }
    }

    fn group(&mut self) -> Result<Node, Error> {
        if self.depth >= MAX_NESTING {
            return Err(self.err(ErrorKind::NestingTooDeep));
        }
        self.pos += 1; // '('
        self.groups += 1;
        let id = self.groups;
        self.depth += 1;
        let inner = self.regex()?;
        self.depth -= 1;
        if self.peek() != Some(b')') {
            return Err(self.err(ErrorKind::UnclosedGroup));
        }
        self.pos += 1;
        Ok(Node::Group(id, Box::new(inner)))
    }

    /// Returns the set for a `\d`-style escape letter, if it is one.
    fn set_escape(b: u8) -> Option<CharSet> {
        let (mut set, negate) = match b {
            b'd' => (CharSet::digit(), false),
            b'D' => (CharSet::digit(), true),
            b'w' => (CharSet::word(), false),
            b'W' => (CharSet::word(), true),
            b's' => (CharSet::space(), false),
            b'S' => (CharSet::space(), true),
            _ => return None,
        };
        if negate {
            set.negate();
        }
        Some(set)
    }

    /// An escape outside a class (the cursor is on the backslash).
    fn escape(&mut self) -> Result<Node, Error> {
        let Some(b) = self.peek_at(1) else {
            return Err(self.err(ErrorKind::InvalidEscape));
        };
        if let Some(set) = Self::set_escape(b) {
            self.pos += 2;
            return Ok(Node::Set(set));
        }
        if b.is_ascii_alphanumeric() {
            return Err(self.err(ErrorKind::InvalidEscape));
        }
        self.pos += 2;
        Ok(Node::Char(b))
    }

    /// A single class character, possibly escaped. The cursor is on it.
    fn class_char(&mut self) -> Result<u8, Error> {
        let b = self.peek().ok_or_else(|| self.err(ErrorKind::UnclosedClass))?;
        if b == b'\\' {
            match self.peek_at(1) {
                Some(e) if !e.is_ascii_alphanumeric() => {
                    self.pos += 2;
                    Ok(e)
                }
                _ => Err(self.err(ErrorKind::InvalidEscape)),
            }
        } else {
            self.pos += 1;
            Ok(b)
        }
    }

    fn class(&mut self) -> Result<Node, Error> {
        self.pos += 1; // '['
        let negated = self.peek() == Some(b'^');
        if negated {
            self.pos += 1;
        }
        let mut set = CharSet::new();
        let mut items = 0usize;
        loop {
            let Some(b) = self.peek() else {
                return Err(self.err(ErrorKind::UnclosedClass));
            };
            if b == b']' {
                self.pos += 1;
                break;
            }
            items += 1;
            if b == b'\\' {
                if let Some(s) = self.peek_at(1).and_then(Self::set_escape) {
                    set.union_with(&s);
                    self.pos += 2;
                    continue;
                }
            }
            let lo = self.class_char()?;
            // A '-' followed by something other than ']' is a range operator.
            if self.peek() == Some(b'-') && !matches!(self.peek_at(1), Some(b']') | None) {
                self.pos += 1;
                if self.peek() == Some(b'\\') {
                    if let Some(e) = self.peek_at(1) {
                        if e.is_ascii_alphanumeric() {
                            return Err(self.err(ErrorKind::InvalidRange));
                        }
                    }
                }
                let hi = self.class_char()?;
                if hi < lo {
                    return Err(self.err(ErrorKind::InvalidRange));
                }
                set.insert_range(lo, hi);
            } else {
                set.insert(lo);
            }
        }
        if items == 0 {
            return Err(self.err(ErrorKind::EmptyClass));
        }
        if negated {
            set.negate();
        }
        Ok(Node::Set(set))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn p(s: &str) -> Result<Parsed, Error> {
        parse(s.as_bytes())
    }

    fn kind(s: &str) -> ErrorKind {
        p(s).unwrap_err().kind()
    }

    #[test]
    fn literals_and_concat() {
        assert_eq!(p("a").unwrap().node, Node::Char(b'a'));
        assert_eq!(
            p("ab").unwrap().node,
            Node::Concat(vec![Node::Char(b'a'), Node::Char(b'b')])
        );
        assert_eq!(p("").unwrap().node, Node::Empty);
    }

    #[test]
    fn alternation_with_empty_branches() {
        match p("a||").unwrap().node {
            Node::Alt(v) => assert_eq!(v, vec![Node::Char(b'a'), Node::Empty, Node::Empty]),
            n => panic!("unexpected {:?}", n),
        }
    }

    #[test]
    fn groups_are_numbered_by_open_paren() {
        let r = p("((a)b)(c)").unwrap();
        assert_eq!(r.group_count, 3);
    }

    #[test]
    fn counted_quantifiers() {
        let r = |s: &str| match p(s).unwrap().node {
            Node::Repeat { min, max, .. } => (min, max),
            n => panic!("unexpected {:?}", n),
        };
        assert_eq!(r("a{3}"), (3, Some(3)));
        assert_eq!(r("a{2,}"), (2, None));
        assert_eq!(r("a{2,5}"), (2, Some(5)));
        assert_eq!(r("a{0}"), (0, Some(0)));
        assert_eq!(r("a*"), (0, None));
        assert_eq!(r("a+"), (1, None));
        assert_eq!(r("a?"), (0, Some(1)));
    }

    #[test]
    fn classes() {
        let set = |s: &str| match p(s).unwrap().node {
            Node::Set(c) => c,
            n => panic!("unexpected {:?}", n),
        };
        let c = set("[a-c-]");
        assert!(c.contains(b'b') && c.contains(b'-') && !c.contains(b'd'));
        let c = set("[-a]");
        assert!(c.contains(b'-') && c.contains(b'a'));
        let c = set("[^a\\]]");
        assert!(!c.contains(b'a') && !c.contains(b']') && c.contains(b'b'));
        let c = set("[\\d_]");
        assert!(c.contains(b'5') && c.contains(b'_') && !c.contains(b'a'));
        let c = set("[a^]");
        assert!(c.contains(b'^'));
        let c = set("[\\--/]");
        assert!(c.contains(b'.') && c.contains(b'/') && !c.contains(b'0'));
    }

    #[test]
    fn escapes() {
        assert_eq!(p("\\.").unwrap().node, Node::Char(b'.'));
        assert_eq!(p("\\ ").unwrap().node, Node::Char(b' '));
        assert!(matches!(p("\\D").unwrap().node, Node::Set(_)));
    }

    #[test]
    fn errors() {
        assert_eq!(kind("(a"), ErrorKind::UnclosedGroup);
        assert_eq!(kind("a)"), ErrorKind::UnmatchedCloseParen);
        assert_eq!(kind("*a"), ErrorKind::DanglingQuantifier);
        assert_eq!(kind("a|*"), ErrorKind::DanglingQuantifier);
        assert_eq!(kind("(*)"), ErrorKind::DanglingQuantifier);
        assert_eq!(kind("a**"), ErrorKind::RepeatedQuantifier);
        assert_eq!(kind("a+?"), ErrorKind::RepeatedQuantifier);
        assert_eq!(kind("^*"), ErrorKind::QuantifierOnAnchor);
        assert_eq!(kind("a{"), ErrorKind::InvalidQuantifier);
        assert_eq!(kind("a{,3}"), ErrorKind::InvalidQuantifier);
        assert_eq!(kind("a{3,2}"), ErrorKind::InvalidQuantifier);
        assert_eq!(kind("a{01}"), ErrorKind::InvalidQuantifier);
        assert_eq!(kind("a{101}"), ErrorKind::RepeatTooLarge);
        assert_eq!(kind("\\b"), ErrorKind::InvalidEscape);
        assert_eq!(kind("a\\"), ErrorKind::InvalidEscape);
        assert_eq!(kind("]"), ErrorKind::UnexpectedMeta);
        assert_eq!(kind("a}"), ErrorKind::UnexpectedMeta);
        assert_eq!(kind("[a"), ErrorKind::UnclosedClass);
        assert_eq!(kind("[]"), ErrorKind::EmptyClass);
        assert_eq!(kind("[z-a]"), ErrorKind::InvalidRange);
    }

    #[test]
    fn nesting_limit() {
        let deep = format!("{}a{}", "(".repeat(MAX_NESTING + 1), ")".repeat(MAX_NESTING + 1));
        assert_eq!(kind(&deep), ErrorKind::NestingTooDeep);
    }
}
