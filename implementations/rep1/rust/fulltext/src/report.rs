//! Formatting of `results.txt` and `stats.txt`, and `queries.txt` parsing.

use crate::analysis::is_space;
use crate::index::Index;
use crate::search::Searcher;
use std::fmt::Write;

/// The default result limit.
pub const DEFAULT_K: usize = 10;

/// One line of `queries.txt`, classified.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Line<'a> {
    /// Blank or comment: ignored.
    Ignored,
    /// A `%k <digits>` directive.
    SetK(usize),
    /// A query, with its stripped text.
    Query(&'a str),
}

/// Classifies one line of the queries file.
pub fn classify_line(line: &str) -> Line<'_> {
    let text = line.trim_matches(is_space);
    if text.is_empty() || text.starts_with('#') {
        return Line::Ignored;
    }
    if let Some(rest) = text.strip_prefix("%k") {
        let blank = |c: char| c == ' ' || c == '\t';
        let after = rest.trim_start_matches(blank);
        if after.len() < rest.len() {
            let digits = after.trim_end_matches(blank);
            if !digits.is_empty() && digits.bytes().all(|b| b.is_ascii_digit()) {
                let k = digits
                    .bytes()
                    .fold(0usize, |k, b| k.saturating_mul(10).saturating_add((b - b'0') as usize));
                return Line::SetK(k);
            }
        }
    }
    Line::Query(text)
}

/// Runs every query in `queries` (the contents of `queries.txt`) and returns
/// the text of `results.txt`.
pub fn run_queries(index: &Index, queries: &str) -> String {
    let searcher = Searcher::new(index);
    let mut out = String::new();
    let mut k = DEFAULT_K;
    let mut number = 0;
    for line in queries.split('\n') {
        match classify_line(line) {
            Line::Ignored => {}
            Line::SetK(n) => k = n,
            Line::Query(text) => {
                number += 1;
                let hits = searcher.search(text, k);
                let _ = writeln!(out, "QUERY {number} {text}");
                let _ = writeln!(out, "HITS {}", hits.len());
                for (rank, hit) in hits.iter().enumerate() {
                    let _ = writeln!(
                        out,
                        "{}\t{}\t{:.4}\t{}",
                        rank + 1,
                        hit.id,
                        hit.score,
                        hit.snippet
                    );
                }
            }
        }
    }
    out
}

/// The text of `stats.txt`.
pub fn stats(index: &Index) -> String {
    format!(
        "documents {}\ntokens {}\nterms {}\navgdl {:.4}\n",
        index.num_docs(),
        index.total_tokens(),
        index.num_terms(),
        index.avgdl()
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn line_classification() {
        assert_eq!(classify_line("  # note"), Line::Ignored);
        assert_eq!(classify_line("\u{A0}\t"), Line::Ignored);
        assert_eq!(classify_line("%k 5"), Line::SetK(5));
        assert_eq!(classify_line("%k \t 25 \t"), Line::SetK(25));
        assert_eq!(classify_line("  cat dog \u{A0}"), Line::Query("cat dog"));
        assert_eq!(classify_line("%k5"), Line::Query("%k5"));
        assert_eq!(classify_line("%k x"), Line::Query("%k x"));
    }

    #[test]
    fn worked_example_output() {
        let idx = Index::build(vec![("note", "The quick brown fox jumps over the lazy dog.\n")]);
        let out = run_queries(&idx, "fox\nquick brown\ncat\n\"lazy dog\"");
        assert_eq!(
            out,
            "QUERY 1 fox\nHITS 1\n1\tnote\t0.2877\tThe quick brown fox jumps over the lazy dog\n\
             QUERY 2 quick brown\nHITS 1\n1\tnote\t0.5754\tThe quick brown fox jumps over the lazy dog\n\
             QUERY 3 cat\nHITS 0\n\
             QUERY 4 \"lazy dog\"\nHITS 1\n1\tnote\t0.2877\tThe quick brown fox jumps over the lazy dog\n"
        );
        assert_eq!(stats(&idx), "documents 1\ntokens 9\nterms 8\navgdl 9.0000\n");
    }

    #[test]
    fn k_directive_applies_to_later_queries() {
        let idx = Index::build(vec![("a", "x1"), ("b", "x1"), ("c", "x1")]);
        let out = run_queries(&idx, "x1\n%k 1\nx1\n");
        assert!(out.contains("QUERY 1 x1\nHITS 3"));
        assert!(out.contains("QUERY 2 x1\nHITS 1"));
    }
}
