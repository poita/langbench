//! Snippet selection: the best window of tokens and its rendering.

use crate::analysis::is_space;
use crate::index::Document;

/// The window size in tokens.
pub const WINDOW: usize = 30;

/// The occurrences of one positive atom inside one document.
#[derive(Debug, Clone, Copy)]
pub struct AtomOccurrences<'a> {
    /// Number of terms in the atom.
    pub len: usize,
    /// Sorted start positions of the occurrences.
    pub starts: &'a [u32],
}

/// Finds the start of the best window in a document of `doc_len` tokens.
///
/// The best window maximises the number of distinct atoms with an occurrence
/// fully inside it, then the total number of occurrences inside it, then
/// prefers the smallest start. Runs in O(doc_len + occurrences) using
/// difference arrays over the window starts.
pub fn best_window(doc_len: usize, atoms: &[AtomOccurrences<'_>]) -> usize {
    if doc_len <= WINDOW {
        return 0;
    }
    let last_start = doc_len - WINDOW;
    // diff arrays: index s in 0..=last_start, plus one slot for the end.
    let mut distinct = vec![0i64; last_start + 2];
    let mut total = vec![0i64; last_start + 2];
    for atom in atoms {
        if atom.len == 0 || atom.len > WINDOW {
            continue;
        }
        // An occurrence at p lies inside window s iff p + len - WINDOW <= s <= p
        // (and s <= last_start, which p + len <= doc_len guarantees for the
        // lower end). Both bounds grow with p, so the ranges of one atom can be
        // merged into disjoint ones to count the atom once per window.
        let mut current: Option<(usize, usize)> = None;
        for &p in atom.starts {
            let p = p as usize;
            let lo = (p + atom.len).saturating_sub(WINDOW);
            let hi = p.min(last_start);
            total[lo] += 1;
            total[hi + 1] -= 1;
            current = match current {
                Some((clo, chi)) if lo <= chi + 1 => Some((clo, hi.max(chi))),
                Some((clo, chi)) => {
                    distinct[clo] += 1;
                    distinct[chi + 1] -= 1;
                    Some((lo, hi))
                }
                None => Some((lo, hi)),
            };
        }
        if let Some((clo, chi)) = current {
            distinct[clo] += 1;
            distinct[chi + 1] -= 1;
        }
    }
    let (mut best, mut best_key) = (0usize, (-1i64, -1i64));
    let (mut d, mut t) = (0i64, 0i64);
    for s in 0..=last_start {
        d += distinct[s];
        t += total[s];
        if (d, t) > best_key {
            best_key = (d, t);
            best = s;
        }
    }
    best
}

/// Renders the snippet for the window starting at token `start`: the original
/// text from the first token of the window to its last, with each run of
/// whitespace collapsed to one space.
pub fn render(doc: &Document, start: usize) -> String {
    let n = doc.tokens.len();
    if n == 0 {
        return String::new();
    }
    let end = (start + WINDOW).min(n) - 1;
    let slice = &doc.text[doc.tokens[start].start..doc.tokens[end].end];
    let mut out = String::with_capacity(slice.len());
    let mut in_space = false;
    for c in slice.chars() {
        if is_space(c) {
            if !in_space {
                out.push(' ');
            }
            in_space = true;
        } else {
            out.push(c);
            in_space = false;
        }
    }
    out
}

/// Builds the snippet of `doc` for the given atom occurrences.
pub fn snippet(doc: &Document, atoms: &[AtomOccurrences<'_>]) -> String {
    render(doc, best_window(doc.tokens.len(), atoms))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::index::Index;

    fn occ(len: usize, starts: &[u32]) -> AtomOccurrences<'_> {
        AtomOccurrences { len, starts }
    }

    #[test]
    fn short_documents_and_no_occurrences_start_at_zero() {
        assert_eq!(best_window(10, &[occ(1, &[9])]), 0);
        assert_eq!(best_window(100, &[]), 0);
        assert_eq!(best_window(100, &[occ(31, &[5])]), 0);
    }

    #[test]
    fn prefers_more_distinct_atoms_then_more_occurrences_then_earlier() {
        // atom A at 0 and 60; atom B at 60..: the window covering 60 has both.
        let a = [0u32, 60];
        let b = [65u32];
        assert_eq!(best_window(100, &[occ(1, &a), occ(1, &b)]), 36);
        // Equal distinct counts: more occurrences wins.
        let a = [0u32, 50, 52, 54];
        assert_eq!(best_window(100, &[occ(1, &a)]), 25);
        // Ties: smallest start.
        let a = [10u32, 80];
        assert_eq!(best_window(100, &[occ(1, &a)]), 0);
    }

    #[test]
    fn occurrence_must_fit_entirely() {
        // A 3-term atom at 28 does not fit in window 0 (covers 0..=29).
        let a = [28u32];
        assert_eq!(best_window(100, &[occ(3, &a)]), 1);
    }

    #[test]
    fn matches_brute_force() {
        let doc_len = 97;
        let a = [3u32, 4, 40, 41, 42, 90];
        let b = [5u32, 44, 94];
        let atoms = [occ(2, &a), occ(1, &b)];
        let mut best = (0usize, (-1i64, -1i64));
        for s in 0..=doc_len - WINDOW {
            let end = s + WINDOW;
            let mut distinct = 0;
            let mut total = 0;
            for at in &atoms {
                let n = at.starts.iter().filter(|&&p| p as usize >= s && p as usize + at.len <= end).count();
                distinct += (n > 0) as i64;
                total += n as i64;
            }
            if (distinct, total) > best.1 {
                best = (s, (distinct, total));
            }
        }
        assert_eq!(best_window(doc_len, &atoms), best.0);
    }

    #[test]
    fn rendering_collapses_whitespace() {
        let idx = Index::build(vec![("d", "  Hello,\n\n  big\u{A0}\tworld!  ")]);
        let doc = idx.document(0);
        assert_eq!(render(doc, 0), "Hello, big world");
        let empty = Index::build(vec![("e", "...")]);
        assert_eq!(render(empty.document(0), 0), "");
    }
}
