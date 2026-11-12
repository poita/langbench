//! KBL glob patterns.
//!
//! A pattern is split on `/` into components. `**` (as a whole component)
//! matches zero or more candidate components; any other component is a
//! sequence of items (`*`, `?`, byte classes, literal bytes) matched within a
//! single candidate component.

#[derive(Debug, Clone, PartialEq, Eq)]
enum Item {
    Star,
    Any,
    Byte(u8),
    Class { negated: bool, ranges: Vec<(u8, u8)> },
}

impl Item {
    fn matches(&self, b: u8) -> bool {
        match self {
            Item::Star => false,
            Item::Any => true,
            Item::Byte(x) => *x == b,
            Item::Class { negated, ranges } => {
                ranges.iter().any(|&(lo, hi)| lo <= b && b <= hi) != *negated
            }
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum Component {
    DoubleStar,
    Items(Vec<Item>),
}

/// A compiled glob pattern.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Pattern {
    comps: Vec<Component>,
    prefix: Vec<u8>,
    has_double_star: bool,
}

impl Pattern {
    /// Compiles a pattern; `None` if it is malformed.
    ///
    /// ```
    /// use kiln::glob::Pattern;
    /// let p = Pattern::compile(b"src/**/t_*.txt").unwrap();
    /// assert!(p.is_match(b"src/a/b/t_2.txt"));
    /// assert!(!p.is_match(b"src/t.txt"));
    /// assert!(Pattern::compile(b"a//b").is_none());
    /// ```
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
                comps.push(Component::DoubleStar);
            } else {
                comps.push(Component::Items(compile_component(part)?));
            }
        }
        let has_double_star = comps.contains(&Component::DoubleStar);
        // Literal prefix: the bytes before the first wildcard. If the first
        // wildcard component is a trailing `**`, the bare directory itself
        // also matches, so the trailing '/' is dropped from the prefix.
        let first_meta = pat
            .iter()
            .position(|b| matches!(b, b'*' | b'?' | b'['))
            .unwrap_or(pat.len());
        let mut prefix = pat[..first_meta].to_vec();
        if prefix.last() == Some(&b'/') && &pat[first_meta..] == b"**" {
            prefix.pop();
        }
        Some(Pattern {
            comps,
            prefix,
            has_double_star,
        })
    }

    /// The wildcard-free prefix every match must start with.
    pub fn literal_prefix(&self) -> &str {
        // Patterns used for prefix lookup are ASCII in practice; fall back to
        // the empty prefix (scan everything) if not valid UTF-8.
        std::str::from_utf8(&self.prefix).unwrap_or("")
    }

    /// Whether the pattern matches the whole candidate string.
    pub fn is_match(&self, candidate: &[u8]) -> bool {
        let cand: Vec<&[u8]> = candidate.split(|&b| b == b'/').collect();
        let np = self.comps.len();
        let nc = cand.len();
        if !self.has_double_star {
            return np == nc
                && self.comps.iter().zip(&cand).all(|(c, s)| match c {
                    Component::Items(items) => match_component(items, s),
                    Component::DoubleStar => unreachable!(),
                });
        }
        // dp[i][j]: comps[i..] matches cand[j..]
        let w = nc + 1;
        let mut dp = vec![false; (np + 1) * w];
        dp[np * w + nc] = true;
        for i in (0..np).rev() {
            for j in (0..=nc).rev() {
                dp[i * w + j] = match &self.comps[i] {
                    Component::DoubleStar => {
                        dp[(i + 1) * w + j] || (j < nc && dp[i * w + j + 1])
                    }
                    Component::Items(items) => {
                        j < nc && dp[(i + 1) * w + j + 1] && match_component(items, cand[j])
                    }
                };
            }
        }
        dp[0]
    }
}

fn compile_component(part: &[u8]) -> Option<Vec<Item>> {
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
                let (item, next) = compile_class(part, i + 1)?;
                items.push(item);
                i = next;
            }
            b => {
                items.push(Item::Byte(b));
                i += 1;
            }
        }
    }
    Some(items)
}

/// Parses a class body starting just after `[`; returns the item and the
/// index just after the closing `]`.
fn compile_class(part: &[u8], mut i: usize) -> Option<(Item, usize)> {
    let negated = part.get(i) == Some(&b'!');
    if negated {
        i += 1;
    }
    let mut ranges = Vec::new();
    loop {
        let &c = part.get(i)?;
        if c == b']' {
            if ranges.is_empty() {
                return None;
            }
            return Some((Item::Class { negated, ranges }, i + 1));
        }
        if part.get(i + 1) == Some(&b'-') && part.get(i + 2).is_some_and(|&z| z != b']') {
            let hi = part[i + 2];
            if c > hi {
                return None;
            }
            ranges.push((c, hi));
            i += 3;
        } else {
            ranges.push((c, c));
            i += 1;
        }
    }
}

/// Matches one component's items against one candidate component, with
/// single-star backtracking (linear in pattern × candidate at worst).
fn match_component(items: &[Item], s: &[u8]) -> bool {
    let (mut i, mut j) = (0usize, 0usize);
    let mut star: Option<(usize, usize)> = None;
    while j < s.len() {
        if i < items.len() {
            if items[i] == Item::Star {
                star = Some((i, j));
                i += 1;
                continue;
            }
            if items[i].matches(s[j]) {
                i += 1;
                j += 1;
                continue;
            }
        }
        match star {
            Some((si, sj)) => {
                i = si + 1;
                j = sj + 1;
                star = Some((si, sj + 1));
            }
            None => return false,
        }
    }
    items[i..].iter().all(|it| *it == Item::Star)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn m(p: &str, c: &str) -> bool {
        Pattern::compile(p.as_bytes()).unwrap().is_match(c.as_bytes())
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
        assert!(m("a/*", "a/"));
        assert!(m("**", "a//b"));
    }

    #[test]
    fn malformed_patterns() {
        for p in ["", "/a", "a/", "a//b", "[", "[]", "[!]", "[b-a]", "a[bc", "[a-"] {
            assert!(Pattern::compile(p.as_bytes()).is_none(), "{p:?}");
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
        assert!(m("[a-c]x", "bx"));
    }

    #[test]
    fn prefix() {
        let p = Pattern::compile(b"src/a*.txt").unwrap();
        assert_eq!(p.literal_prefix(), "src/a");
        let p = Pattern::compile(b"src/**").unwrap();
        assert_eq!(p.literal_prefix(), "src");
        let p = Pattern::compile(b"**/x").unwrap();
        assert_eq!(p.literal_prefix(), "");
        let p = Pattern::compile(b"src/**/x").unwrap();
        assert_eq!(p.literal_prefix(), "src/");
    }
}
