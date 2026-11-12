//! Query lexing and parsing.
//!
//! The grammar never fails: malformed input is recovered from as described in
//! the specification, and a query may parse to nothing at all (`None`).

use crate::analysis::{analyze, fold, is_space, is_stop_word, tokenize};

/// A search atom: the terms of a phrase, matched at adjacent positions.
pub type Atom = Vec<String>;

/// A node of the parsed query tree.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Node {
    /// A (possibly multi-term) phrase.
    Atom(Atom),
    /// Negation.
    Not(Box<Node>),
    /// Intersection of the children.
    And(Vec<Node>),
    /// Union of the children.
    Or(Vec<Node>),
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum Tok {
    LParen,
    RParen,
    And,
    Or,
    Not,
    /// A phrase or bare word; `None` when it analyses to an empty atom.
    Atom(Option<Atom>),
}

/// Builds the atom for a phrase body: empty if it has no terms or a single
/// stop word.
fn make_atom(body: &str) -> Option<Atom> {
    let terms = analyze(body);
    match terms.len() {
        0 => None,
        1 => {
            let tok = tokenize(body)[0];
            if is_stop_word(&fold(&body[tok.start..tok.end])) {
                None
            } else {
                Some(vec![terms.into_iter().next().unwrap().1])
            }
        }
        _ => Some(terms.into_iter().map(|(_, t)| t).collect()),
    }
}

fn lex(query: &str) -> Vec<Tok> {
    let mut out = Vec::new();
    let mut rest = query;
    while let Some(c) = rest.chars().next() {
        if is_space(c) {
            rest = &rest[c.len_utf8()..];
        } else if c == '(' {
            out.push(Tok::LParen);
            rest = &rest[1..];
        } else if c == ')' {
            out.push(Tok::RParen);
            rest = &rest[1..];
        } else if c == '"' {
            let body = &rest[1..];
            match body.find('"') {
                Some(end) => {
                    out.push(Tok::Atom(make_atom(&body[..end])));
                    rest = &body[end + 1..];
                }
                None => {
                    out.push(Tok::Atom(make_atom(body)));
                    rest = "";
                }
            }
        } else {
            let end = rest
                .find(|ch: char| is_space(ch) || matches!(ch, '(' | ')' | '"'))
                .unwrap_or(rest.len());
            let word = &rest[..end];
            out.push(match word {
                "AND" => Tok::And,
                "OR" => Tok::Or,
                "NOT" => Tok::Not,
                _ => Tok::Atom(make_atom(word)),
            });
            rest = &rest[end..];
        }
    }
    out
}

struct Parser {
    toks: Vec<Tok>,
    pos: usize,
}

/// Collapses collected children: none -> empty, one -> itself, else `make`.
fn combine(mut items: Vec<Node>, make: fn(Vec<Node>) -> Node) -> Option<Node> {
    match items.len() {
        0 => None,
        1 => items.pop(),
        _ => Some(make(items)),
    }
}

impl Parser {
    fn peek(&self) -> Option<&Tok> {
        self.toks.get(self.pos)
    }

    fn or(&mut self) -> Option<Node> {
        let mut items: Vec<Node> = self.and().into_iter().collect();
        while self.peek() == Some(&Tok::Or) {
            self.pos += 1;
            items.extend(self.and());
        }
        combine(items, Node::Or)
    }

    fn and(&mut self) -> Option<Node> {
        let mut items = Vec::new();
        loop {
            match self.peek() {
                None | Some(Tok::RParen) | Some(Tok::Or) => break,
                Some(Tok::And) => self.pos += 1,
                Some(_) => items.extend(self.not()),
            }
        }
        combine(items, Node::And)
    }

    fn not(&mut self) -> Option<Node> {
        let mut count = 0;
        while self.peek() == Some(&Tok::Not) {
            self.pos += 1;
            count += 1;
        }
        let mut node = self.primary()?;
        for _ in 0..count {
            node = Node::Not(Box::new(node));
        }
        Some(node)
    }

    fn primary(&mut self) -> Option<Node> {
        match self.peek()? {
            Tok::LParen => {
                self.pos += 1;
                let inner = self.or();
                if self.peek() == Some(&Tok::RParen) {
                    self.pos += 1;
                }
                inner
            }
            Tok::RParen => None,
            Tok::Atom(a) => {
                let node = a.clone().map(Node::Atom);
                self.pos += 1;
                node
            }
            _ => {
                self.pos += 1;
                None
            }
        }
    }
}

/// Parses a query line into a tree; `None` is the empty tree.
pub fn parse(query: &str) -> Option<Node> {
    let mut parser = Parser { toks: lex(query), pos: 0 };
    parser.or()
}

/// Collects the positive atoms (under an even number of `NOT`s) in
/// depth-first, left-to-right order, dropping duplicates.
pub fn positive_atoms(tree: &Option<Node>) -> Vec<Atom> {
    fn walk(node: &Node, positive: bool, out: &mut Vec<Atom>) {
        match node {
            Node::Atom(a) => {
                if positive && !out.contains(a) {
                    out.push(a.clone());
                }
            }
            Node::Not(n) => walk(n, !positive, out),
            Node::And(c) | Node::Or(c) => c.iter().for_each(|n| walk(n, positive, out)),
        }
    }
    let mut out = Vec::new();
    if let Some(n) = tree {
        walk(n, true, &mut out);
    }
    out
}

/// Collects every distinct atom of the tree, positive or not.
pub fn all_atoms(tree: &Option<Node>) -> Vec<Atom> {
    fn walk(node: &Node, out: &mut Vec<Atom>) {
        match node {
            Node::Atom(a) => {
                if !out.contains(a) {
                    out.push(a.clone());
                }
            }
            Node::Not(n) => walk(n, out),
            Node::And(c) | Node::Or(c) => c.iter().for_each(|n| walk(n, out)),
        }
    }
    let mut out = Vec::new();
    if let Some(n) = tree {
        walk(n, &mut out);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn a(s: &str) -> Node {
        Node::Atom(vec![s.to_string()])
    }

    #[test]
    fn empty_trees() {
        for q in ["()", "the", "NOT", "", "\"\"", ")", "NOT NOT"] {
            assert_eq!(parse(q), None, "{q}");
        }
    }

    #[test]
    fn recovery_to_single_atom() {
        for q in ["cat AND", "OR cat", "cat ()", "cat NOT ()", "cat NOT (", "(cat", "\"cat",
                  "cat ) dog", "cat ) ) dog"] {
            assert_eq!(parse(q), Some(a("cat")), "{q}");
        }
    }

    #[test]
    fn adjacent_operators() {
        let or = Some(Node::Or(vec![a("cat"), a("dog")]));
        assert_eq!(parse("cat OR AND dog"), or);
        assert_eq!(parse("cat AND OR dog"), or);
        let and = Some(Node::And(vec![a("cat"), a("dog")]));
        assert_eq!(parse("cat AND AND dog"), and);
        assert_eq!(parse("cat dog"), and);
    }

    #[test]
    fn precedence_and_not() {
        assert_eq!(
            parse("dog NOT ( cat"),
            Some(Node::And(vec![a("dog"), Node::Not(Box::new(a("cat")))]))
        );
        assert_eq!(
            parse("a1 OR b1 c1"),
            Some(Node::Or(vec![a("a1"), Node::And(vec![a("b1"), a("c1")])]))
        );
        assert_eq!(
            parse("NOT NOT cat"),
            Some(Node::Not(Box::new(Node::Not(Box::new(a("cat"))))))
        );
    }

    #[test]
    fn atoms() {
        assert_eq!(parse("well-known"), Some(Node::Atom(vec!["well".into(), "known".into()])));
        assert_eq!(
            parse("\"to be\""),
            Some(Node::Atom(vec!["to".into(), "be".into()]))
        );
        assert_eq!(parse("running"), Some(a("run")));
    }

    #[test]
    fn positive_atom_list() {
        let t = parse("cat NOT dog OR NOT NOT cat fish");
        assert_eq!(positive_atoms(&t), vec![vec!["cat".to_string()], vec!["fish".to_string()]]);
        assert!(positive_atoms(&parse("NOT cat")).is_empty());
        assert_eq!(all_atoms(&parse("NOT cat dog")).len(), 2);
    }
}
