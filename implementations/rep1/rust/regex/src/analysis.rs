//! Static analysis of a syntax tree: nullability, first-byte sets, anchoring.

use crate::ast::Node;
use crate::charset::ByteSet;

/// Returns true if `node` can match without consuming input.
///
/// Conservative: anchors count as nullable.
pub fn nullable(node: &Node) -> bool {
    match node {
        Node::Char(_) | Node::Any | Node::Set(_) => false,
        Node::Bol | Node::Eol => true,
        Node::Group(_, n) => nullable(n),
        Node::Concat(v) => v.iter().all(nullable),
        Node::Alt(v) => v.iter().any(nullable),
        Node::Repeat { node, min, max } => *min == 0 || *max == Some(0) || nullable(node),
    }
}

/// Adds to `set` every byte that can start a non-empty match of `node`, and
/// returns whether `node` is nullable.
pub fn first_bytes(node: &Node, set: &mut ByteSet) -> bool {
    match node {
        Node::Char(c) => {
            set.insert(*c);
            false
        }
        Node::Any => {
            *set = ByteSet::full();
            false
        }
        Node::Set(s) => {
            set.union_with(s);
            false
        }
        Node::Bol | Node::Eol => true,
        Node::Group(_, n) => first_bytes(n, set),
        Node::Concat(v) => {
            for x in v {
                if !first_bytes(x, set) {
                    return false;
                }
            }
            true
        }
        Node::Alt(v) => {
            let mut nullable = false;
            for b in v {
                nullable |= first_bytes(b, set);
            }
            nullable
        }
        Node::Repeat { node, min, max } => {
            if *max == Some(0) {
                return true;
            }
            let n = first_bytes(node, set);
            n || *min == 0
        }
    }
}

/// Returns true if every match of `node` must begin at offset 0 of the subject.
pub fn anchored_at_start(node: &Node) -> bool {
    match node {
        Node::Bol => true,
        Node::Group(_, n) => anchored_at_start(n),
        Node::Concat(v) => v.first().is_some_and(anchored_at_start),
        Node::Alt(v) => v.iter().all(anchored_at_start),
        Node::Repeat { node, min, .. } => *min > 0 && anchored_at_start(node),
        _ => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::parser::parse;

    fn first(p: &str) -> Option<Vec<u8>> {
        let n = parse(p.as_bytes()).unwrap().node;
        let mut s = ByteSet::new();
        if first_bytes(&n, &mut s) {
            None
        } else {
            Some((0..=255u8).filter(|&b| s.contains(b)).collect())
        }
    }

    #[test]
    fn first_sets() {
        assert_eq!(first("abc"), Some(b"a".to_vec()));
        assert_eq!(first("a*b"), Some(b"ab".to_vec()));
        assert_eq!(first("(x|y)z"), Some(b"xy".to_vec()));
        assert_eq!(first("a*"), None);
        assert_eq!(first("a|"), None);
        assert_eq!(first("^b"), Some(b"b".to_vec()));
        assert_eq!(first("(a){0}b"), Some(b"b".to_vec()));
    }

    #[test]
    fn anchoring() {
        let a = |p: &str| anchored_at_start(&parse(p.as_bytes()).unwrap().node);
        assert!(a("^abc"));
        assert!(a("^a|^b"));
        assert!(a("(^a)b"));
        assert!(!a("a|^b"));
        assert!(!a("a^"));
        assert!(!a(""));
    }
}
