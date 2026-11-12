// Predicate identity: a predicate is a (name, arity) pair.
#pragma once

#include <cstddef>
#include <cstdint>
#include <map>
#include <optional>
#include <string>
#include <utility>
#include <vector>

#include "datalog/ast.h"

namespace datalog {

using PredId = std::uint32_t;

/// Interns (name, arity) pairs into dense ids.
class PredicateTable {
 public:
  /// Collects every predicate used in `program` (heads, bodies, queries).
  static PredicateTable of(const Program& program);

  PredId intern(const std::string& name, std::size_t arity);
  std::optional<PredId> find(const std::string& name, std::size_t arity) const;

  std::size_t size() const { return keys_.size(); }
  const std::string& name(PredId id) const { return keys_[id].first; }
  std::size_t arity(PredId id) const { return keys_[id].second; }

 private:
  std::map<std::pair<std::string, std::size_t>, PredId> ids_;
  std::vector<std::pair<std::string, std::size_t>> keys_;
};

}  // namespace datalog
