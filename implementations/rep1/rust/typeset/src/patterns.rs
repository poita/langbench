//! Liang hyphenation patterns (`.chp` files) and the hyphenation of single
//! words and fragments.

use std::collections::HashMap;
use std::fs;
use std::io;
use std::path::Path;

/// One pattern set: patterns, exceptions and the `left`/`right` minima.
#[derive(Clone, Debug, Default)]
pub struct Patterns {
    pub left: usize,
    pub right: usize,
    patterns: HashMap<Vec<u8>, Vec<u8>>,
    exceptions: HashMap<Vec<u8>, Vec<usize>>,
    max_key: usize,
}

impl Patterns {
    /// Parses the text of a `.chp` file.
    pub fn parse(text: &str) -> Patterns {
        let mut p = Patterns::default();
        for raw in text.split('\n') {
            let line = match raw.find('#') {
                Some(i) => &raw[..i],
                None => raw,
            };
            let line = line.trim_matches(|c| c == ' ' || c == '\t');
            let mut it = line.split([' ', '\t']).filter(|s| !s.is_empty());
            let (Some(kind), Some(arg)) = (it.next(), it.next()) else { continue };
            match kind {
                "left" => p.left = arg.parse().unwrap_or(0),
                "right" => p.right = arg.parse().unwrap_or(0),
                "pattern" => {
                    let mut key = Vec::new();
                    let mut vals = vec![0u8];
                    for b in arg.bytes() {
                        if b.is_ascii_digit() {
                            *vals.last_mut().unwrap() = b - b'0';
                        } else {
                            key.push(b);
                            vals.push(0);
                        }
                    }
                    p.max_key = p.max_key.max(key.len());
                    p.patterns.insert(key, vals);
                }
                "exception" => {
                    let mut word = Vec::new();
                    let mut points = Vec::new();
                    for b in arg.bytes() {
                        if b == b'-' {
                            points.push(word.len());
                        } else {
                            word.push(b);
                        }
                    }
                    p.exceptions.insert(word, points);
                }
                _ => {}
            }
        }
        p
    }

    /// Loads a `.chp` file.
    pub fn load(path: &Path) -> io::Result<Patterns> {
        Ok(Patterns::parse(&fs::read_to_string(path)?))
    }

    /// Hyphenation positions of a lowercase ASCII word: each `q` means "a
    /// break is allowed after `q` letters". Sorted ascending.
    pub fn hyphenate(&self, word: &[u8]) -> Vec<usize> {
        let n = word.len();
        let mut found: Vec<usize> = if let Some(points) = self.exceptions.get(word) {
            points.clone()
        } else {
            let mut t = Vec::with_capacity(n + 2);
            t.push(b'.');
            t.extend_from_slice(word);
            t.push(b'.');
            let mut v = vec![0u8; n + 3];
            for i in 0..t.len() {
                let jmax = (i + self.max_key).min(t.len());
                for j in i + 1..=jmax {
                    if let Some(vals) = self.patterns.get(&t[i..j]) {
                        for (k, &x) in vals.iter().enumerate() {
                            if x > v[i + k] {
                                v[i + k] = x;
                            }
                        }
                    }
                }
            }
            (1..n).filter(|&q| v[1 + q] % 2 == 1).collect()
        };
        found.retain(|&q| q >= self.left && q + self.right <= n && q >= 1 && q < n);
        found.sort_unstable();
        found.dedup();
        found
    }
}

/// A permitted break inside a fragment.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Break {
    /// Position in the fragment (the break comes before character `pos`).
    pub pos: usize,
    /// `true` for a break after a literal `-` (no pre-break text, uses the
    /// explicit-hyphen penalty); `false` for a discretionary hyphen.
    pub after_hyphen: bool,
}

fn is_letter(c: char) -> bool {
    c.is_ascii_alphabetic()
}

/// Computes the hyphenation points of one fragment.
///
/// `discs` are the positions of explicit `\-` points. The caller has already
/// applied the gating rules (hyphenation enabled, non-mono face).
pub fn fragment_breaks(chars: &[char], discs: &[usize], pats: &Patterns) -> Vec<Break> {
    let n = chars.len();
    let Some(lo) = chars.iter().position(|&c| is_letter(c)) else { return Vec::new() };
    let hi = chars.iter().rposition(|&c| is_letter(c)).unwrap() + 1;

    let explicit: Vec<usize> = discs.iter().copied().filter(|&p| p > 0 && p < n).collect();
    let mut out: Vec<Break> = Vec::new();

    // Segments of the core, split at '-'.
    let mut seg_start = lo;
    for i in lo..=hi {
        if i == hi || chars[i] == '-' {
            let seg = &chars[seg_start..i];
            if explicit.is_empty()
                && !seg.is_empty()
                && seg.iter().all(|&c| is_letter(c))
            {
                let word: Vec<u8> = seg.iter().map(|&c| c.to_ascii_lowercase() as u8).collect();
                for q in pats.hyphenate(&word) {
                    out.push(Break { pos: seg_start + q, after_hyphen: false });
                }
            }
            if i < hi {
                out.push(Break { pos: i + 1, after_hyphen: true });
                seg_start = i + 1;
            }
        }
    }
    for p in explicit {
        out.push(Break { pos: p, after_hyphen: false });
    }
    out.retain(|b| b.pos > 0 && b.pos < n);
    // Sort by position; at equal positions the core-hyphen break wins.
    out.sort_by_key(|b| (b.pos, !b.after_hyphen));
    out.dedup_by_key(|b| b.pos);
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn english() -> Patterns {
        Patterns::parse(&std::fs::read_to_string(concat!(env!("CARGO_MANIFEST_DIR"), "/data/hyphen/english.chp")).unwrap())
    }

    #[test]
    fn parses_pattern_values() {
        let p = Patterns::parse("chp 1\nleft 2\nright 3\npattern .anti3\npattern c2h\n");
        assert_eq!(p.patterns[&b".anti"[..]], vec![0, 0, 0, 0, 0, 3]);
        assert_eq!(p.patterns[&b"ch"[..]], vec![0, 2, 0]);
    }

    #[test]
    fn spec_worked_traces() {
        let p = english();
        assert_eq!(p.hyphenate(b"winter"), vec![3]);
        assert_eq!(p.hyphenate(b"typesetting"), vec![7, 8]);
        assert_eq!(p.hyphenate(b"national"), vec![2, 4]);
        assert_eq!(p.hyphenate(b"introduction"), vec![2, 8]);
        assert_eq!(p.hyphenate(b"algorithm"), vec![2, 4]);
    }

    #[test]
    fn fragment_with_explicit_point_skips_liang() {
        let p = english();
        let chars: Vec<char> = "typesetting".chars().collect();
        let b = fragment_breaks(&chars, &[4], &p);
        assert_eq!(b, vec![Break { pos: 4, after_hyphen: false }]);
        let b = fragment_breaks(&chars, &[11], &p);
        assert_eq!(b.len(), 2);
    }

    #[test]
    fn core_hyphens_and_punctuation() {
        let p = english();
        let chars: Vec<char> = "(well-known)".chars().collect();
        let b = fragment_breaks(&chars, &[], &p);
        assert!(b.iter().any(|x| x.after_hyphen && x.pos == 6));
    }
}
