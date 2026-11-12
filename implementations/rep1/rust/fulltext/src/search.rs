//! Query evaluation: phrase matching, boolean set algebra, BM25 scoring and
//! ranking.

use crate::index::{DocId, Index, Posting};
use crate::query::{all_atoms, parse, positive_atoms, Atom, Node};
use crate::snippet::{snippet, AtomOccurrences};
use std::collections::HashMap;

/// BM25 term-frequency saturation parameter.
pub const K1: f64 = 1.2;
/// BM25 length normalisation parameter.
pub const B: f64 = 0.75;

/// All occurrences of one atom in the corpus.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct AtomMatch {
    /// Number of terms in the atom.
    pub len: usize,
    /// For each document containing the atom (ascending), the sorted start
    /// positions of its occurrences.
    pub docs: Vec<(DocId, Vec<u32>)>,
}

impl AtomMatch {
    /// The start positions of the atom in `doc`, if it occurs there.
    pub fn occurrences(&self, doc: DocId) -> Option<&[u32]> {
        self.docs
            .binary_search_by_key(&doc, |(d, _)| *d)
            .ok()
            .map(|i| self.docs[i].1.as_slice())
    }

    /// Document frequency.
    pub fn df(&self) -> usize {
        self.docs.len()
    }
}

/// Finds every occurrence of `atom` in the index by intersecting the
/// position lists of its terms, shifted by their offsets.
pub fn match_atom(index: &Index, atom: &Atom) -> AtomMatch {
    let mut result = AtomMatch { len: atom.len(), docs: Vec::new() };
    let mut lists: Vec<&[Posting]> = Vec::with_capacity(atom.len());
    for term in atom {
        match index.postings(term) {
            Some(p) => lists.push(p),
            None => return result,
        }
    }
    if lists.is_empty() {
        return result;
    }
    if lists.len() == 1 {
        result.docs = lists[0].iter().map(|p| (p.doc, p.positions.clone())).collect();
        return result;
    }
    // Walk the first term's postings, advancing a cursor in every other list.
    let mut cursors = vec![0usize; lists.len()];
    'docs: for first in lists[0] {
        let mut found: Vec<&Posting> = Vec::with_capacity(lists.len());
        found.push(first);
        for (i, list) in lists.iter().enumerate().skip(1) {
            while cursors[i] < list.len() && list[cursors[i]].doc < first.doc {
                cursors[i] += 1;
            }
            if cursors[i] == list.len() {
                break 'docs; // no later document can match either
            }
            if list[cursors[i]].doc != first.doc {
                continue 'docs;
            }
            found.push(&list[cursors[i]]);
        }
        let mut starts = first.positions.clone();
        for (offset, p) in found.iter().enumerate().skip(1) {
            let mut j = 0;
            let positions = &p.positions;
            starts.retain(|&s| {
                let want = s + offset as u32;
                while j < positions.len() && positions[j] < want {
                    j += 1;
                }
                j < positions.len() && positions[j] == want
            });
            if starts.is_empty() {
                break;
            }
        }
        if !starts.is_empty() {
            result.docs.push((first.doc, starts));
        }
    }
    result
}

/// One ranked result.
#[derive(Debug, Clone, PartialEq)]
pub struct Hit {
    /// Index of the document.
    pub doc: DocId,
    /// The document id.
    pub id: String,
    /// The BM25 score.
    pub score: f64,
    /// The best-window snippet.
    pub snippet: String,
}

/// Evaluates queries against an [`Index`].
pub struct Searcher<'a> {
    index: &'a Index,
}

impl<'a> Searcher<'a> {
    /// Creates a searcher over `index`.
    pub fn new(index: &'a Index) -> Self {
        Searcher { index }
    }

    /// Runs `query` and returns at most `k` ranked hits, with snippets.
    pub fn search(&self, query: &str, k: usize) -> Vec<Hit> {
        let index = self.index;
        let tree = parse(query);
        let Some(root) = &tree else { return Vec::new() };

        // Match every distinct atom once.
        let matches: HashMap<Atom, AtomMatch> =
            all_atoms(&tree).into_iter().map(|a| { let m = match_atom(index, &a); (a, m) }).collect();
        let matched = self.evaluate(root, &matches);

        let positive = positive_atoms(&tree);
        let positive_matches: Vec<&AtomMatch> = positive.iter().map(|a| &matches[a]).collect();
        let n = index.num_docs() as f64;
        let idfs: Vec<f64> = positive_matches
            .iter()
            .map(|m| {
                let df = m.df() as f64;
                ((n - df + 0.5) / (df + 0.5) + 1.0).ln()
            })
            .collect();
        let avgdl = index.avgdl();

        let mut scored: Vec<(DocId, f64)> = Vec::new();
        for (doc, &hit) in matched.iter().enumerate() {
            if !hit {
                continue;
            }
            let doc = doc as DocId;
            let ratio = if avgdl == 0.0 { 0.0 } else { index.doc_len(doc) as f64 / avgdl };
            let norm = K1 * (1.0 - B + B * ratio);
            let mut score = 0.0;
            for (m, &idf) in positive_matches.iter().zip(&idfs) {
                if let Some(occ) = m.occurrences(doc) {
                    let f = occ.len() as f64;
                    score += idf * (f * (K1 + 1.0) / (f + norm));
                }
            }
            scored.push((doc, score));
        }
        scored.sort_by(|a, b| b.1.total_cmp(&a.1).then(a.0.cmp(&b.0)));
        scored.truncate(k);

        scored
            .into_iter()
            .map(|(doc, score)| {
                let occ: Vec<AtomOccurrences<'_>> = positive_matches
                    .iter()
                    .filter_map(|m| {
                        m.occurrences(doc).map(|starts| AtomOccurrences { len: m.len, starts })
                    })
                    .collect();
                let document = index.document(doc);
                Hit { doc, id: document.id.clone(), score, snippet: snippet(document, &occ) }
            })
            .collect()
    }

    /// Evaluates the tree to a per-document match flag.
    fn evaluate(&self, node: &Node, matches: &HashMap<Atom, AtomMatch>) -> Vec<bool> {
        let n = self.index.num_docs();
        match node {
            Node::Atom(a) => {
                let mut flags = vec![false; n];
                for (doc, _) in &matches[a].docs {
                    flags[*doc as usize] = true;
                }
                flags
            }
            Node::Not(inner) => {
                let mut flags = self.evaluate(inner, matches);
                flags.iter_mut().for_each(|f| *f = !*f);
                flags
            }
            Node::And(children) | Node::Or(children) => {
                let is_and = matches!(node, Node::And(_));
                let mut iter = children.iter();
                let mut acc = self.evaluate(iter.next().expect("non-empty node"), matches);
                for child in iter {
                    let other = self.evaluate(child, matches);
                    for (a, o) in acc.iter_mut().zip(other) {
                        *a = if is_and { *a && o } else { *a || o };
                    }
                }
                acc
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn index(docs: &[(&str, &str)]) -> Index {
        Index::build(docs.iter().map(|&(a, b)| (a, b)))
    }

    fn ids(hits: &[Hit]) -> Vec<&str> {
        hits.iter().map(|h| h.id.as_str()).collect()
    }

    #[test]
    fn worked_example_score() {
        let idx = index(&[("note", "The quick brown fox jumps over the lazy dog.")]);
        let s = Searcher::new(&idx);
        let hits = s.search("fox", 10);
        assert_eq!(hits.len(), 1);
        assert!((hits[0].score - (4.0f64 / 3.0).ln()).abs() < 1e-12);
        assert_eq!(hits[0].snippet, "The quick brown fox jumps over the lazy dog");
        let two = s.search("quick brown", 10);
        assert!((two[0].score - 2.0 * (4.0f64 / 3.0).ln()).abs() < 1e-12);
        assert!(s.search("cat", 10).is_empty());
        assert_eq!(s.search("\"lazy dog\"", 10).len(), 1);
    }

    #[test]
    fn tie_break_by_id() {
        let idx = index(&[
            ("copy3", "alpha beta gamma"),
            ("copy1", "alpha beta gamma"),
            ("other", "alpha alpha beta"),
            ("copy2", "alpha beta gamma"),
        ]);
        let hits = Searcher::new(&idx).search("alpha", 10);
        assert_eq!(ids(&hits), ["other", "copy1", "copy2", "copy3"]);
        assert_eq!(ids(&Searcher::new(&idx).search("alpha", 2)), ["other", "copy1"]);
    }

    #[test]
    fn overlapping_phrase_occurrences() {
        let idx = index(&[("d", "aa1 aa1 aa1 aa1")]);
        let m = match_atom(&idx, &vec!["aa1".to_string(), "aa1".to_string()]);
        assert_eq!(m.docs, vec![(0, vec![0, 1, 2])]);
    }

    #[test]
    fn phrases_use_stop_words_and_adjacency() {
        let idx = index(&[("a", "to be or not to be"), ("b", "be to"), ("c", "to x be")]);
        let s = Searcher::new(&idx);
        assert_eq!(ids(&s.search("\"to be\"", 10)), ["a"]);
        assert_eq!(ids(&s.search("\"be or not\"", 10)), ["a"]);
    }

    #[test]
    fn boolean_operators() {
        let idx = index(&[("a", "cat dog"), ("b", "cat"), ("c", "dog"), ("d", "fish")]);
        let s = Searcher::new(&idx);
        assert_eq!(ids(&s.search("cat AND dog", 10)), ["a"]);
        let mut or = ids(&s.search("cat OR dog", 10)).into_iter().map(String::from).collect::<Vec<_>>();
        or.sort();
        assert_eq!(or, ["a", "b", "c"]);
        let not = s.search("NOT cat", 10);
        assert_eq!(ids(&not), ["c", "d"]);
        assert!(not.iter().all(|h| h.score == 0.0));
        assert!(s.search("()", 10).is_empty());
        assert!(s.search("the", 10).is_empty());
    }

    #[test]
    fn empty_corpus() {
        let idx = index(&[]);
        assert!(Searcher::new(&idx).search("cat", 10).is_empty());
        assert!(Searcher::new(&idx).search("NOT cat", 10).is_empty());
    }
}
