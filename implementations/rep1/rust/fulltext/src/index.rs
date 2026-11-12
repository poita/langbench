//! The positional inverted index and the document collection.

use crate::analysis::{analyze, Token};
use std::collections::HashMap;
use std::fs;
use std::io;
use std::path::Path;

/// Index of a document within an [`Index`]. Documents are numbered in
/// increasing id order, so comparing `DocId`s compares document ids.
pub type DocId = u32;

/// One document: its id, original text and the byte span of every token.
#[derive(Debug, Clone)]
pub struct Document {
    /// The document id (file name without `.txt`).
    pub id: String,
    /// The full original text.
    pub text: String,
    /// Byte span of each token, indexed by token position.
    pub tokens: Vec<Token>,
}

/// The positions of one term in one document.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Posting {
    /// The document.
    pub doc: DocId,
    /// Sorted token positions at which the term occurs.
    pub positions: Vec<u32>,
}

/// A positional inverted index over a set of documents.
#[derive(Debug, Default)]
pub struct Index {
    docs: Vec<Document>,
    postings: HashMap<String, Vec<Posting>>,
    total_tokens: usize,
}

impl Index {
    /// Builds an index from `(id, text)` pairs. Documents are ordered by id
    /// (byte order); ids are expected to be unique.
    pub fn build<I, S, T>(documents: I) -> Index
    where
        I: IntoIterator<Item = (S, T)>,
        S: Into<String>,
        T: Into<String>,
    {
        let mut raw: Vec<(String, String)> =
            documents.into_iter().map(|(i, t)| (i.into(), t.into())).collect();
        raw.sort_by(|a, b| a.0.cmp(&b.0));

        let mut index = Index::default();
        for (n, (id, text)) in raw.into_iter().enumerate() {
            let doc = n as DocId;
            let analysed = analyze(&text);
            let mut tokens = Vec::with_capacity(analysed.len());
            for (pos, (token, term)) in analysed.into_iter().enumerate() {
                tokens.push(token);
                let list = index.postings.entry(term).or_default();
                match list.last_mut() {
                    Some(p) if p.doc == doc => p.positions.push(pos as u32),
                    _ => list.push(Posting { doc, positions: vec![pos as u32] }),
                }
            }
            index.total_tokens += tokens.len();
            index.docs.push(Document { id, text, tokens });
        }
        index
    }

    /// Loads the corpus from `<input>/docs/*.txt` and indexes it. A missing
    /// `docs` directory yields an empty index.
    pub fn from_directory(input: &Path) -> io::Result<Index> {
        let dir = input.join("docs");
        let mut documents = Vec::new();
        let entries = match fs::read_dir(&dir) {
            Ok(entries) => entries,
            Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(Index::default()),
            Err(e) => return Err(e),
        };
        for entry in entries {
            let path = entry?.path();
            let Some(name) = path.file_name().and_then(|n| n.to_str()) else { continue };
            let Some(id) = name.strip_suffix(".txt") else { continue };
            if !path.is_file() {
                continue;
            }
            let bytes = fs::read(&path)?;
            documents.push((id.to_string(), String::from_utf8_lossy(&bytes).into_owned()));
        }
        Ok(Index::build(documents))
    }

    /// The documents, ordered by id.
    pub fn documents(&self) -> &[Document] {
        &self.docs
    }

    /// The document with the given index.
    pub fn document(&self, doc: DocId) -> &Document {
        &self.docs[doc as usize]
    }

    /// Number of documents, `N`.
    pub fn num_docs(&self) -> usize {
        self.docs.len()
    }

    /// Length of a document in tokens, `|d|`.
    pub fn doc_len(&self, doc: DocId) -> usize {
        self.docs[doc as usize].tokens.len()
    }

    /// Total number of tokens in the corpus.
    pub fn total_tokens(&self) -> usize {
        self.total_tokens
    }

    /// Number of distinct terms.
    pub fn num_terms(&self) -> usize {
        self.postings.len()
    }

    /// Mean document length; 0 for an empty corpus.
    pub fn avgdl(&self) -> f64 {
        if self.docs.is_empty() {
            0.0
        } else {
            self.total_tokens as f64 / self.docs.len() as f64
        }
    }

    /// The postings of a term (documents in increasing order), if any.
    pub fn postings(&self, term: &str) -> Option<&[Posting]> {
        self.postings.get(term).map(Vec::as_slice)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn builds_postings_and_stats() {
        let idx = Index::build(vec![("b", "cat dog cat"), ("a", "dog")]);
        assert_eq!(idx.num_docs(), 2);
        assert_eq!(idx.document(0).id, "a");
        assert_eq!(idx.total_tokens(), 4);
        assert_eq!(idx.num_terms(), 2);
        assert_eq!(idx.avgdl(), 2.0);
        let cat = idx.postings("cat").unwrap();
        assert_eq!(cat, &[Posting { doc: 1, positions: vec![0, 2] }]);
        assert_eq!(idx.postings("dog").unwrap().len(), 2);
        assert!(idx.postings("fish").is_none());
    }

    #[test]
    fn empty_index() {
        let idx = Index::build(Vec::<(String, String)>::new());
        assert_eq!(idx.avgdl(), 0.0);
        assert_eq!(idx.num_terms(), 0);
    }
}
