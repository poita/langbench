/// @file query.hpp
/// The query language: lexer and recursive-descent parser.
///
/// ```
/// query   := or
/// or      := and ( "OR" and )*
/// and     := ( "AND" | not )*
/// not     := "NOT"* primary
/// primary := "(" or ")" | atom
/// ```
/// Parsing never fails: malformed input is recovered from exactly as SPEC.md
/// describes. Juxtaposition means AND; the empty tree matches nothing.
#pragma once

#include <memory>
#include <string>
#include <string_view>
#include <vector>

namespace fulltext {

/// A search atom: the sequence of terms of a phrase (or bare word). Atoms
/// with zero terms, or a single stop word, are dropped by the parser and
/// never appear in a tree.
using Atom = std::vector<std::string>;

/// A node of the parse tree.
struct QueryNode {
  enum class Kind { Atom, And, Or, Not };

  Kind kind = Kind::Atom;
  Atom atom;                                      ///< Kind::Atom only.
  std::vector<std::unique_ptr<QueryNode>> children;  ///< And/Or: 2+; Not: exactly 1.
};

/// A parsed query.
struct Query {
  /// Root of the tree; null for the empty tree.
  std::unique_ptr<QueryNode> root;
  /// Atoms under an even number of NOTs, in first-met order, without
  /// duplicates.
  std::vector<Atom> positive_atoms;
};

/// Parses a query line (already stripped of surrounding whitespace).
Query parse_query(std::string_view text);

}  // namespace fulltext
