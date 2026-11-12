#pragma once
/// \file filters.hpp
/// The thirteen built-in filters.

#include <string_view>
#include <vector>

#include "jinjalite/value.hpp"

namespace jinjalite {

/// Description of one built-in filter.
struct FilterInfo {
  const char* name;
  size_t min_args;
  size_t max_args;
  /// Only `default` accepts an undefined input.
  bool accepts_undefined;
  /// Computes the filter. `input` is defined unless `accepts_undefined`.
  /// The argument count has already been validated.
  Value (*apply)(const Value& input, const std::vector<Value>& args);
};

/// Looks a filter up by name; nullptr if there is no such filter.
const FilterInfo* find_filter(std::string_view name);

}  // namespace jinjalite
