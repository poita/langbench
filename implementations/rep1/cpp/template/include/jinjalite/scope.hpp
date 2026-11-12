#pragma once
/// \file scope.hpp
/// Lexical scopes: a mapping from names to values plus a parent scope.

#include <memory>
#include <string>
#include <string_view>
#include <unordered_map>
#include <utility>
#include <vector>

#include "jinjalite/value.hpp"

namespace jinjalite {

class Scope;
using ScopePtr = std::shared_ptr<Scope>;

/// Creating a scope is O(1); a lookup walks the parent chain.
class Scope {
 public:
  /// A child scope of `parent` (which may be null for the root).
  explicit Scope(ScopePtr parent) : parent_(std::move(parent)) {}
  /// The root scope, backed by the JSON context members.
  explicit Scope(DictPtr context) : context_(std::move(context)) {}

  /// Binds `name` in this scope only.
  void set(std::string_view name, Value value);

  /// The binding visible from this scope, or nullptr.
  const Value* find(std::string_view name) const;

  const ScopePtr& parent() const { return parent_; }

 private:
  static constexpr size_t kLinearLimit = 8;
  struct Hash {
    using is_transparent = void;
    size_t operator()(std::string_view s) const noexcept { return std::hash<std::string_view>{}(s); }
  };

  ScopePtr parent_;
  DictPtr context_;  // only for the root scope
  std::vector<std::pair<std::string, Value>> vars_;
  std::unordered_map<std::string, size_t, Hash, std::equal_to<>> index_;
};

}  // namespace jinjalite
