//! Recursive-descent parser from pattern bytes to an [`ast::Node`](crate::ast::Node).
//!
//! The grammar is described in the crate documentation. Patterns are treated
//! as raw bytes; every metacharacter is ASCII.

use crate::ast::Node;
use crate::charset::ByteSet;
use crate::error::Error;

/// Largest accepted value of a counted-quantifier bound.
pub const MAX_REPEAT: u32 = 1000;
/// Deepest accepted nesting of groups.
pub const MAX_DEPTH: usize = 500;

/// The result of parsing a pattern.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Parsed {
    /// The syntax tree of the whole pattern.
    pub node: Node,
    /// The number of capture groups in the pattern.
    pub group_count: usize,
}

/// Parses `pattern` into a syntax tree.
pub fn parse(pattern: &[u8]) -> Result<Parsed, Error> {
    let mut p = Parser { src: pattern, pos: 0, groups: 0 };
    let node = p.parse_alt(0)?;
    if p.pos < p.src.len() {
        return p.err("unmatched ')'");
    }
    Ok(Parsed { node, group_count: p.groups })
}

enum Escape {
    Set(ByteSet),
    Byte(u8),
}

struct Parser<'a> {
    src: &'a [u8],
    pos: usize,
    groups: usize,
}

impl Parser<'_> {
    fn err<T>(&self, message: &'static str) -> Result<T, Error> {
        Err(Error::Syntax { offset: self.pos, message })
    }

    fn peek(&self) -> Option<u8> {
        self.src.get(self.pos).copied()
    }

    fn next(&mut self) -> Option<u8> {
        let c = self.peek();
        if c.is_some() {
            self.pos += 1;
        }
        c
    }

    fn parse_alt(&mut self, depth: usize) -> Result<Node, Error> {
        let mut branches = vec![self.parse_concat(depth)?];
        while self.peek() == Some(b'|') {
            self.pos += 1;
            branches.push(self.parse_concat(depth)?);
        }
        Ok(if branches.len() == 1 { branches.pop().unwrap() } else { Node::Alt(branches) })
    }

    fn parse_concat(&mut self, depth: usize) -> Result<Node, Error> {
        let mut items = Vec::new();
        while let Some(c) = self.peek() {
            if c == b'|' || c == b')' {
                break;
            }
            items.push(self.parse_piece(depth)?);
        }
        Ok(if items.len() == 1 { items.pop().unwrap() } else { Node::Concat(items) })
    }

    fn parse_piece(&mut self, depth: usize) -> Result<Node, Error> {
        let atom = self.parse_atom(depth)?;
        let (min, max) = match self.peek() {
            Some(b'*') => (0, None),
            Some(b'+') => (1, None),
            Some(b'?') => (0, Some(1)),
            Some(b'{') => {
                if matches!(atom, Node::Bol | Node::Eol) {
                    return self.err("quantifier after anchor");
                }
                let q = self.parse_braces()?;
                return Ok(Node::Repeat { node: Box::new(atom), min: q.0, max: q.1 });
            }
            _ => return Ok(atom),
        };
        if matches!(atom, Node::Bol | Node::Eol) {
            return self.err("quantifier after anchor");
        }
        self.pos += 1;
        Ok(Node::Repeat { node: Box::new(atom), min, max })
    }

    /// Parses `{n}`, `{n,}` or `{n,m}` starting at the `{`.
    fn parse_braces(&mut self) -> Result<(u32, Option<u32>), Error> {
        self.pos += 1; // '{'
        let n = self.parse_number()?;
        let (min, max) = match self.next() {
            Some(b'}') => (n, Some(n)),
            Some(b',') => {
                if self.peek() == Some(b'}') {
                    self.pos += 1;
                    (n, None)
                } else {
                    let m = self.parse_number()?;
                    if self.next() != Some(b'}') {
                        return self.err("expected '}' in quantifier");
                    }
                    (n, Some(m))
                }
            }
            _ => return self.err("invalid quantifier"),
        };
        if let Some(m) = max {
            if m < min {
                return self.err("quantifier minimum exceeds maximum");
            }
        }
        Ok((min, max))
    }

    fn parse_number(&mut self) -> Result<u32, Error> {
        let start = self.pos;
        let mut v: u32 = 0;
        while let Some(c @ b'0'..=b'9') = self.peek() {
            v = v * 10 + (c - b'0') as u32;
            if v > MAX_REPEAT {
                return self.err("quantifier bound too large");
            }
            self.pos += 1;
        }
        if self.pos == start {
            return self.err("expected a number in quantifier");
        }
        Ok(v)
    }

    fn parse_atom(&mut self, depth: usize) -> Result<Node, Error> {
        let c = match self.next() {
            Some(c) => c,
            None => return self.err("unexpected end of pattern"),
        };
        match c {
            b'(' => {
                if depth >= MAX_DEPTH {
                    return self.err("groups nested too deeply");
                }
                self.groups += 1;
                let g = self.groups;
                let inner = self.parse_alt(depth + 1)?;
                if self.next() != Some(b')') {
                    return self.err("unclosed group");
                }
                Ok(Node::Group(g, Box::new(inner)))
            }
            b'.' => Ok(Node::Any),
            b'^' => Ok(Node::Bol),
            b'$' => Ok(Node::Eol),
            b'[' => self.parse_class(),
            b'\\' => Ok(match self.parse_escape()? {
                Escape::Set(s) => Node::Set(s),
                Escape::Byte(b) => Node::Char(b),
            }),
            b'*' | b'+' | b'?' | b'{' => {
                self.pos -= 1;
                self.err("nothing to repeat")
            }
            b'}' | b']' => {
                self.pos -= 1;
                self.err("unescaped brace or bracket")
            }
            _ => Ok(Node::Char(c)),
        }
    }

    /// Parses the part after a backslash.
    fn parse_escape(&mut self) -> Result<Escape, Error> {
        let c = match self.next() {
            Some(c) => c,
            None => return self.err("pattern ends with a backslash"),
        };
        let set = |mut s: ByteSet, negate: bool| {
            if negate {
                s.negate();
            }
            Ok(Escape::Set(s))
        };
        match c {
            b'd' => set(ByteSet::digits(), false),
            b'D' => set(ByteSet::digits(), true),
            b'w' => set(ByteSet::word(), false),
            b'W' => set(ByteSet::word(), true),
            b's' => set(ByteSet::space(), false),
            b'S' => set(ByteSet::space(), true),
            c if c.is_ascii_alphanumeric() => self.err("unknown escape"),
            c => Ok(Escape::Byte(c)),
        }
    }

    /// Parses a bracketed class; the `[` has been consumed.
    fn parse_class(&mut self) -> Result<Node, Error> {
        let negate = self.peek() == Some(b'^');
        if negate {
            self.pos += 1;
        }
        let mut set = ByteSet::new();
        let mut items = 0usize;
        loop {
            let c = match self.next() {
                Some(c) => c,
                None => return self.err("unterminated character class"),
            };
            if c == b']' {
                if items == 0 {
                    return self.err("empty character class");
                }
                break;
            }
            items += 1;
            let lo = if c == b'\\' {
                match self.parse_escape()? {
                    Escape::Set(s) => {
                        set.union_with(&s);
                        continue;
                    }
                    Escape::Byte(b) => b,
                }
            } else {
                c
            };
            // `x-y` is a range unless the '-' is the last character of the class.
            let is_range =
                self.peek() == Some(b'-') && self.src.get(self.pos + 1).is_some_and(|&n| n != b']');
            if !is_range {
                set.insert(lo);
                continue;
            }
            self.pos += 1; // '-'
            let h = self.next().unwrap();
            let hi = if h == b'\\' {
                match self.parse_escape()? {
                    Escape::Set(_) => return self.err("class escape as range endpoint"),
                    Escape::Byte(b) => b,
                }
            } else {
                h
            };
            if hi < lo {
                return self.err("reversed range in character class");
            }
            set.insert_range(lo, hi);
        }
        if negate {
            set.negate();
        }
        Ok(Node::Set(set))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ok(p: &str) -> Parsed {
        parse(p.as_bytes()).unwrap_or_else(|e| panic!("{p:?}: {e}"))
    }

    fn bad(p: &str) {
        assert!(parse(p.as_bytes()).is_err(), "{p:?} should be rejected");
    }

    #[test]
    fn empty_pattern_and_branches() {
        assert_eq!(ok("").node, Node::Concat(vec![]));
        assert_eq!(
            ok("a|").node,
            Node::Alt(vec![Node::Char(b'a'), Node::Concat(vec![])])
        );
        assert_eq!(ok("||").node, Node::Alt(vec![Node::Concat(vec![]); 3]));
    }

    #[test]
    fn groups_are_numbered_by_open_paren() {
        let p = ok("((a)(b))(c)");
        assert_eq!(p.group_count, 4);
        match p.node {
            Node::Concat(v) => match &v[0] {
                Node::Group(1, inner) => match &**inner {
                    Node::Concat(w) => {
                        assert!(matches!(w[0], Node::Group(2, _)));
                        assert!(matches!(w[1], Node::Group(3, _)));
                    }
                    n => panic!("{n:?}"),
                },
                n => panic!("{n:?}"),
            },
            n => panic!("{n:?}"),
        }
    }

    #[test]
    fn quantifiers() {
        let rep = |p: &str| match ok(p).node {
            Node::Repeat { min, max, .. } => (min, max),
            n => panic!("{n:?}"),
        };
        assert_eq!(rep("a*"), (0, None));
        assert_eq!(rep("a+"), (1, None));
        assert_eq!(rep("a?"), (0, Some(1)));
        assert_eq!(rep("a{3}"), (3, Some(3)));
        assert_eq!(rep("a{2,}"), (2, None));
        assert_eq!(rep("a{0,0}"), (0, Some(0)));
        assert_eq!(rep("(ab){2,5}"), (2, Some(5)));
    }

    #[test]
    fn classes() {
        let set = |p: &str| match ok(p).node {
            Node::Set(s) => s,
            n => panic!("{n:?}"),
        };
        let s = set("[a-c-]");
        assert!(s.contains(b'b') && s.contains(b'-') && !s.contains(b'd'));
        let s = set("[-a]");
        assert!(s.contains(b'-') && s.contains(b'a'));
        let s = set("[^a-c]");
        assert!(!s.contains(b'b') && s.contains(b'z'));
        let s = set("[a^]");
        assert!(s.contains(b'^') && s.contains(b'a'));
        let s = set("[\\]\\-\\\\]");
        assert!(s.contains(b']') && s.contains(b'-') && s.contains(b'\\'));
        let s = set("[\\d_]");
        assert!(s.contains(b'5') && s.contains(b'_') && !s.contains(b'a'));
        let s = set("[--/]");
        assert!(s.contains(b'-') && s.contains(b'.') && s.contains(b'/') && !s.contains(b'0'));
    }

    #[test]
    fn escapes() {
        assert_eq!(ok("\\.").node, Node::Char(b'.'));
        assert_eq!(ok("\\ ").node, Node::Char(b' '));
        assert!(matches!(ok("\\D").node, Node::Set(s) if s.contains(b'a') && !s.contains(b'1')));
        assert!(matches!(ok("\\s").node, Node::Set(s) if s.contains(b' ')));
    }

    #[test]
    fn rejects_invalid_patterns() {
        for p in [
            "(", ")", "a)", "(a", "*", "a**", "a+*", "^*", "$+", "a{", "a{1", "a{1,", "a{,2}",
            "a{3,2}", "[", "[a", "[]", "[z-a]", "\\", "\\q", "a{x}", "|*", "(*)", "}", "]",
        ] {
            bad(p);
        }
    }
}
