/// @file index.hpp
/// The positional inverted index and corpus statistics.
#pragma once

#include <cstddef>
#include <cstdint>
#include <span>
#include <string>
#include <string_view>
#include <unordered_map>
#include <vector>

namespace fulltext {

/// Documents are numbered `0..N-1` in ascending order of document id, so
/// comparing `DocId`s is the same as comparing the ids (the ranking tie-break).
using DocId = std::uint32_t;

/// A document: its id (file name without `.txt`) and its UTF-8 text.
struct Document {
  std::string id;
  std::string text;
};

/// For one term (or one matched phrase): the documents containing it, in
/// ascending order, and for each the ascending list of positions.
///
/// For an index term the positions are token positions; for the result of
/// matching a multi-term atom they are the start positions of its occurrences.
class PostingList {
 public:
  static constexpr std::size_t npos = static_cast<std::size_t>(-1);

  /// Number of documents in the list (the document frequency).
  std::size_t size() const noexcept { return docs_.size(); }
  bool empty() const noexcept { return docs_.empty(); }

  /// Ascending document ids.
  std::span<const DocId> docs() const noexcept { return docs_; }
  DocId doc(std::size_t i) const noexcept { return docs_[i]; }

  /// Positions in the i-th document.
  std::span<const std::uint32_t> positions(std::size_t i) const noexcept;

  /// Number of occurrences in the i-th document.
  std::size_t frequency(std::size_t i) const noexcept { return positions(i).size(); }

  /// Index of document `d` in this list, or `npos`.
  std::size_t find(DocId d) const noexcept;

  /// Appends a document. `d` must exceed every document already present and
  /// `positions` must be non-empty and ascending.
  void append(DocId d, std::span<const std::uint32_t> positions);

  /// Incremental form of `append` used while indexing: starts a new document
  /// (or continues the last one if it is `d`) and adds one position.
  void add_position(DocId d, std::uint32_t position);

 private:
  std::vector<DocId> docs_;
  std::vector<std::uint32_t> offsets_;  // start of each document's positions
  std::vector<std::uint32_t> positions_;
};

/// An immutable positional inverted index over a set of documents.
class Index {
 public:
  Index() = default;

  /// Analyses every document and builds the index. Documents are sorted by id
  /// (byte order) first; the document order of the result is that order.
  static Index build(std::vector<Document> documents);

  /// Number of documents, `N`.
  std::size_t num_docs() const noexcept { return docs_.size(); }
  /// Total number of tokens over all documents.
  std::size_t total_tokens() const noexcept { return total_tokens_; }
  /// Number of distinct terms (stop words included).
  std::size_t num_terms() const noexcept { return postings_.size(); }
  /// Mean document length; 0 when there are no documents.
  double avgdl() const noexcept { return avgdl_; }

  const Document& document(DocId d) const noexcept { return docs_[d]; }
  /// Number of tokens in document `d`, `|d|`.
  std::uint32_t length(DocId d) const noexcept { return lengths_[d]; }

  /// Postings of `term`, or nullptr if the term does not occur.
  const PostingList* find(const std::string& term) const;

 private:
  std::vector<Document> docs_;
  std::vector<std::uint32_t> lengths_;
  std::unordered_map<std::string, std::uint32_t> term_ids_;
  std::vector<PostingList> postings_;
  std::size_t total_tokens_ = 0;
  double avgdl_ = 0.0;
};

}  // namespace fulltext
