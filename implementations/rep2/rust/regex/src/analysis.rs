//! Static analysis of a syntax tree: which bytes can start a match, whether a
//! match may be empty, and whether a match can only start at position 0.
//!
//! These facts drive the two start-position optimisations of the search loop
//! and let the compiler omit empty-iteration checks for loop bodies that
//! always consume input.

use crate::ast::Node;
use crate::charset::CharSet;

/// Summary facts about a sub-pattern.
#[derive(Debug, Clone, Copy)]
pub struct Info {
    /// Superset of bytes that can be the first byte consumed by a match.
    pub first: CharSet,
    /// Whether the sub-pattern may match without consuming anything
    /// (conservatively `true` for anchors).
    pub nullable: bool,
    /// Whether every match necessarily passes through a `^`, so can only
    /// begin at position 0.
    pub anchored: bool,
}

/// Computes [`Info`] for `node`.
pub fn analyze(node: &Node) -> Info {
    match node {
        Node::Empty => Info {
            first: CharSet::new(),
            nullable: true,
            anchored: false,
        },
        Node::Char(c) => {
            let mut first = CharSet::new();
            first.insert(*c);
            Info {
                first,
                nullable: false,
                anchored: false,
            }
        }
        Node::Any => Info {
            first: CharSet::full(),
            nullable: false,
            anchored: false,
        },
        Node::Set(s) => Info {
            first: *s,
            nullable: false,
            anchored: false,
        },
        Node::Bol => Info {
            first: CharSet::new(),
            nullable: true,
            anchored: true,
        },
        Node::Eol => Info {
            first: CharSet::new(),
            nullable: true,
            anchored: false,
        },
        Node::Group(_, inner) => analyze(inner),
        Node::Concat(items) => {
            let mut info = Info {
                first: CharSet::new(),
                nullable: true,
                anchored: false,
            };
            let mut still_nullable = true;
            for item in items {
                let i = analyze(item);
                if still_nullable {
                    info.first.union_with(&i.first);
                }
                still_nullable &= i.nullable;
                // A `^` anywhere in the sequence forces the match to start at 0.
                info.anchored |= i.anchored;
            }
            info.nullable = still_nullable;
            info
        }
        Node::Alt(branches) => {
            let mut info = Info {
                first: CharSet::new(),
                nullable: false,
                anchored: true,
            };
            for b in branches {
                let i = analyze(b);
                info.first.union_with(&i.first);
                info.nullable |= i.nullable;
                info.anchored &= i.anchored;
            }
            info
        }
        Node::Repeat { node, min, max } => {
            if *max == Some(0) {
                return Info {
                    first: CharSet::new(),
                    nullable: true,
                    anchored: false,
                };
            }
            let i = analyze(node);
            Info {
                first: i.first,
                nullable: *min == 0 || i.nullable,
                anchored: *min >= 1 && i.anchored,
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::parser::parse;

    fn info(p: &str) -> Info {
        analyze(&parse(p.as_bytes()).unwrap().node)
    }

    #[test]
    fn first_sets() {
        let i = info("a|bc");
        assert!(i.first.contains(b'a') && i.first.contains(b'b') && !i.first.contains(b'c'));
        assert!(!i.nullable);
        let i = info("a*b");
        assert!(i.first.contains(b'a') && i.first.contains(b'b'));
        assert!(!i.nullable);
    }

    #[test]
    fn nullability() {
        assert!(info("").nullable);
        assert!(info("a*").nullable);
        assert!(info("(a|)b?").nullable);
        assert!(info("$").nullable);
        assert!(info("a{0}").nullable);
        assert!(!info("a+").nullable);
        assert!(!info("(a*)+b").nullable);
    }

    #[test]
    fn anchoring() {
        assert!(info("^a").anchored);
        assert!(info("^a|^b").anchored);
        assert!(!info("^a|b").anchored);
        assert!(info("(^a)+").anchored);
        assert!(!info("(^a)*").anchored);
        assert!(!info("(^a){0}").anchored);
        assert!(!info("a$").anchored);
    }
}
