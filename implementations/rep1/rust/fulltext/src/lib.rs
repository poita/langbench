//! # fulltext
//!
//! A small full-text search engine: a positional inverted index over plain
//! text documents, a hand-written Porter stemmer, a boolean/phrase query
//! language, BM25 ranking and best-window snippets.
//!
//! The pieces, by module:
//!
//! * [`analysis`] – tokenising, case folding, stop words, term production;
//! * [`stemmer`] – the Porter (1980) stemming algorithm;
//! * [`index`] – the document collection and positional inverted index;
//! * [`query`] – the query lexer and recursive-descent parser;
//! * [`search`] – phrase matching, boolean evaluation, BM25 and ranking;
//! * [`snippet`] – best-window selection and snippet rendering;
//! * [`report`] – `queries.txt` handling and the output file formats.
//!
//! ```
//! use fulltext::{Index, Searcher};
//!
//! let index = Index::build(vec![
//!     ("a", "The quick brown fox jumps over the lazy dog."),
//!     ("b", "A quick reply."),
//! ]);
//! let hits = Searcher::new(&index).search("quick AND NOT fox", 10);
//! assert_eq!(hits.len(), 1);
//! assert_eq!(hits[0].id, "b");
//! ```

pub mod analysis;
pub mod index;
pub mod query;
pub mod report;
pub mod search;
pub mod snippet;
pub mod stemmer;

pub use index::{DocId, Document, Index};
pub use search::{Hit, Searcher};
