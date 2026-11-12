//! Glob patterns as used by `glob`, `filter` and `reject`.
//!
//! A pattern is a `/`-separated list of components. `**` (the whole
//! component) matches zero or more whole candidate components; any other
//! component is a sequence of `*`, `?`, `[...]` classes and literal bytes
//! that matches exactly one candidate component.

#[derive(Clone, Debug, PartialEq, Eq)]
enum Item {
    Star,
    Any,
    Lit(u8),
    Class { negated: bool, ranges: Vec<(u8, u8)> },
}

#[derive(Clone, Debug, PartialEq, Eq)]
enum Comp {
    DoubleStar,
    Items(Vec<Item>),
}

/// A compiled glob pattern.
#[derive(Clone, Debug)]
pub struct Pattern {
    comps: Vec<Comp>,
    prefix: Vec<u8>,
}

impl Pattern {
    /// Compiles a pattern; `None` if it is malformed (empty, leading or
    /// trailing `/`, empty component, or a malformed character class).
    pub fn compile(pat: &[u8]) -> Option<Pattern> {
        if pat.is_empty() {
            return None;
        }
        let mut comps = Vec::new();
        for part in pat.split(|&b| b == b'/') {
            if part.is_empty() {
                return None;
            }
            if part == b"**" {
                comps.push(Comp::DoubleStar);
            } else {
                comps.push(Comp::Items(compile_items(part)?));
            }
        }
        // Every match starts with the wildcard-free prefix of the pattern,
        // minus a trailing `/` (because `src/**` matches `src` itself).
        let end = pat.iter().position(|&b| matches!(b, b'*' | b'?' | b'[')).unwrap_or(pat.len());
        let mut prefix = pat[..end].to_vec();
        if prefix.last() == Some(&b'/') {
            prefix.pop();
        }
        Some(Pattern { comps, prefix })
    }

    /// The literal byte prefix every matching candidate must start with.
    pub fn literal_prefix(&self) -> &[u8] {
        &self.prefix
    }

    /// Whether the pattern matches the whole candidate string.
    pub fn matches(&self, candidate: &[u8]) -> bool {
        let cand: Vec<&[u8]> = candidate.split(|&b| b == b'/').collect();
        let m = cand.len();
        // next[j]: pattern components i+1.. match cand[j..]
        let mut next = vec![false; m + 1];
        next[m] = true;
        for comp in self.comps.iter().rev() {
            let mut cur = vec![false; m + 1];
            match comp {
                Comp::DoubleStar => {
                    cur[m] = next[m];
                    for j in (0..m).rev() {
                        cur[j] = next[j] || cur[j + 1];
                    }
                }
                Comp::Items(items) => {
                    for j in 0..m {
                        cur[j] = next[j + 1] && match_items(items, cand[j]);
                    }
                }
            }
            next = cur;
        }
        next[0]
    }
}

fn compile_items(part: &[u8]) -> Option<Vec<Item>> {
    let mut items = Vec::new();
    let mut i = 0;
    while i < part.len() {
        match part[i] {
            b'*' => {
                items.push(Item::Star);
                i += 1;
            }
            b'?' => {
                items.push(Item::Any);
                i += 1;
            }
            b'[' => {
                i += 1;
                let negated = part.get(i) == Some(&b'!');
                if negated {
                    i += 1;
                }
                let mut ranges = Vec::new();
                loop {
                    if i >= part.len() {
                        return None;
                    }
                    if part[i] == b']' {
                        if ranges.is_empty() {
                            return None;
                        }
                        i += 1;
                        break;
                    }
                    if i + 2 < part.len() && part[i + 1] == b'-' && part[i + 2] != b']' {
                        let (x, y) = (part[i], part[i + 2]);
                        if x > y {
                            return None;
                        }
                        ranges.push((x, y));
                        i += 3;
                    } else {
                        ranges.push((part[i], part[i]));
                        i += 1;
                    }
                }
                items.push(Item::Class { negated, ranges });
            }
            b => {
                items.push(Item::Lit(b));
                i += 1;
            }
        }
    }
    Some(items)
}

fn item_matches(item: &Item, b: u8) -> bool {
    match item {
        Item::Star => false,
        Item::Any => true,
        Item::Lit(c) => *c == b,
        Item::Class { negated, ranges } => {
            let hit = ranges.iter().any(|&(lo, hi)| lo <= b && b <= hi);
            hit != *negated
        }
    }
}

/// Matches one component's items against one candidate component, with the
/// usual backtrack-to-the-last-star strategy (only `*` is variable length).
fn match_items(items: &[Item], s: &[u8]) -> bool {
    let (mut p, mut i) = (0usize, 0usize);
    let mut star: Option<(usize, usize)> = None;
    while i < s.len() {
        if p < items.len() && items[p] == Item::Star {
            star = Some((p, i));
            p += 1;
        } else if p < items.len() && item_matches(&items[p], s[i]) {
            p += 1;
            i += 1;
        } else if let Some((sp, si)) = star {
            p = sp + 1;
            i = si + 1;
            star = Some((sp, si + 1));
        } else {
            return false;
        }
    }
    while p < items.len() && items[p] == Item::Star {
        p += 1;
    }
    p == items.len()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn m(pat: &str, cand: &str) -> bool {
        Pattern::compile(pat.as_bytes()).expect("valid pattern").matches(cand.as_bytes())
    }

    #[test]
    fn spec_table() {
        assert!(m("src/*.txt", "src/a.txt"));
        assert!(m("src/*.txt", "src/.txt"));
        assert!(!m("src/*.txt", "src/sub/a.txt"));
        assert!(!m("src/*.txt", "a.txt"));
        assert!(m("src/**", "src/a.txt"));
        assert!(m("src/**", "src/x/y/z.txt"));
        assert!(m("src/**", "src"));
        assert!(!m("src/**", "other/a.txt"));
        assert!(!m("src/**", "srcx"));
        assert!(m("**/*.txt", "a.txt"));
        assert!(m("**/*.txt", "src/a.txt"));
        assert!(m("**/*.txt", "a/b/c.txt"));
        assert!(!m("**/*.txt", "a.text"));
        assert!(m("src/**/t_*.txt", "src/t_1.txt"));
        assert!(m("src/**/t_*.txt", "src/a/b/t_2.txt"));
        assert!(!m("src/**/t_*.txt", "src/t.txt"));
        assert!(m("src/?.txt", "src/a.txt"));
        assert!(!m("src/?.txt", "src/ab.txt"));
        assert!(m("src/[ab]*.txt", "src/a1.txt"));
        assert!(!m("src/[ab]*.txt", "src/c.txt"));
        assert!(m("src/[!ab]*.txt", "src/c.txt"));
        assert!(!m("src/[!ab]*.txt", "src/a.txt"));
        assert!(m("src/[0-9].txt", "src/7.txt"));
        assert!(m("a**b", "axyzb"));
        assert!(m("a**b", "ab"));
        assert!(!m("a**b", "a/b"));
    }

    #[test]
    fn empty_components_in_candidates() {
        assert!(m("*", ""));
        assert!(m("**", ""));
        assert!(!m("?", ""));
        assert!(!m("*", "a//b"));
        assert!(m("*/*", "x/"));
        assert!(m("**/x", "/x"));
    }

    #[test]
    fn malformed_patterns() {
        for bad in ["", "/a", "a/", "a//b", "[", "[]", "[!]", "[a", "[z-a]", "a/[b"] {
            assert!(Pattern::compile(bad.as_bytes()).is_none(), "{bad}");
        }
    }

    #[test]
    fn class_edge_cases() {
        assert!(m("[-a]", "-"));
        assert!(m("[-a]", "a"));
        assert!(m("[a-]", "-"));
        assert!(m("[a-]", "a"));
        assert!(m("[*?]", "*"));
        assert!(m("[*?]", "?"));
        assert!(!m("[*?]", "a"));
    }

    #[test]
    fn prefix() {
        let p = |s: &str| Pattern::compile(s.as_bytes()).unwrap().literal_prefix().to_vec();
        assert_eq!(p("src/**"), b"src");
        assert_eq!(p("src/a*"), b"src/a");
        assert_eq!(p("**/x"), b"");
        assert_eq!(p("a/b.txt"), b"a/b.txt");
    }
}
