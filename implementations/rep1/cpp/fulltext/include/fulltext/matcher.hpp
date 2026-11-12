/// @file matcher.hpp
/// Matching atoms against the index and evaluating the boolean tree.
#pragma once

#include <map>
#include <vector>

#include "fulltext/index.hpp"
#include "fulltext/query.hpp"

namespace fulltext {

/// A sorted set of documents.
using DocSet = std::vector<DocId>;

/// Finds every occurrence of `atom` in the index by positional intersection
/// of the terms' position lists. The result lists, per document, the start
/// positions of the occurrences (overlapping occurrences all count).
/// Linear in the sizes of the position lists involved.
PostingList match_atom(const Index& index, const Atom& atom);

/// Per-query memo of atom matches: each distinct atom is matched once, and the
/// result serves boolean matching, document frequency, term frequency and
/// snippets.
class AtomMatches {
 public:
  explicit AtomMatches(const Index& index) : index_(&index) {}

  /// Returns the (cached) match of `atom`. The reference stays valid for the
  /// lifetime of this object.
  const PostingList& get(const Atom& atom);

 private:
  const Index* index_;
  std::map<Atom, PostingList> cache_;
};

/// Evaluates the tree as set algebra over documents. A null `root` (the empty
/// tree) matches no document. `NOT x` is the complement of `x` within the
/// whole corpus.
DocSet evaluate(const QueryNode* root, AtomMatches& matches, std::size_t num_docs);

}  // namespace fulltext
