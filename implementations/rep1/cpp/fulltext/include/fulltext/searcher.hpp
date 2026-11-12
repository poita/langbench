/// @file searcher.hpp
/// Evaluates a query against an index: parse, match, score, rank, snippet.
#pragma once

#include <cstddef>
#include <string>
#include <string_view>
#include <vector>

#include "fulltext/bm25.hpp"
#include "fulltext/index.hpp"
#include "fulltext/query.hpp"

namespace fulltext {

/// One ranked result.
struct Hit {
  DocId doc;            ///< Internal document number.
  std::string id;       ///< Document id.
  double score;         ///< BM25 score (0 for queries without positive atoms).
  std::string snippet;  ///< Best 30-token window, whitespace-collapsed.
};

/// Result of one query.
struct SearchResult {
  std::size_t total_matches = 0;  ///< Matched documents before the cut at `k`.
  std::vector<Hit> hits;          ///< At most `k`, best first.
};

/// Runs queries against an `Index`, which must outlive the searcher.
class Searcher {
 public:
  explicit Searcher(const Index& index, Bm25Params params = {}) : index_(&index), params_(params) {}

  /// Parses and runs `query_text`, returning the top `k` documents.
  SearchResult search(std::string_view query_text, std::size_t k) const;

  /// Runs an already parsed query.
  SearchResult search(const Query& query, std::size_t k) const;

 private:
  const Index* index_;
  Bm25Params params_;
};

}  // namespace fulltext
