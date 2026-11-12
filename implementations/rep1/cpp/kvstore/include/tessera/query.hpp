#pragma once
/// \file query.hpp
/// Predicates for `find`: the AST, evaluation (spec 17.2) and plan selection (17.3).

#include <memory>
#include <string>
#include <vector>

#include "tessera/value.hpp"

namespace tessera {

enum class CmpOp { Eq, Ne, Lt, Le, Gt, Ge };

struct Predicate {
  enum class Type { And, Or, Not, Exists, Missing, Cmp };
  Type type = Type::Cmp;
  std::unique_ptr<Predicate> lhs;  ///< And / Or / Not (the operand)
  std::unique_ptr<Predicate> rhs;  ///< And / Or
  Path path;                       ///< Exists / Missing / Cmp
  CmpOp op = CmpOp::Eq;            ///< Cmp
  Value value;                     ///< Cmp
};

/// Evaluates a predicate against a document.
bool evaluate(const Predicate& pred, const Value& doc);

/// How `find` will locate candidates.
struct Plan {
  bool use_index = false;
  std::string path;  ///< index path text when `use_index`
  CmpOp op = CmpOp::Eq;
  Value value;

  /// `scan` or `index <path>`.
  std::string describe() const;
};

/// Chooses the plan for `pred` given the paths of the live indexes.
Plan choose_plan(const Predicate& pred, const std::vector<std::string>& live_index_paths);

}  // namespace tessera
