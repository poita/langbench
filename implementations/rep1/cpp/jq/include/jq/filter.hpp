// Compiling and running jq filters.
#pragma once

#include <functional>
#include <memory>
#include <string>
#include <string_view>
#include <vector>

#include "jq/error.hpp"
#include "jq/value.hpp"

namespace jq {

/// A compiled filter: a function from one input value to a stream of outputs.
///
/// Compile once with `Filter::compile`, then `run` it against any number of
/// inputs. A Filter is immutable and may be shared between threads (each
/// `run` keeps its state on its own stack).
class Filter {
 public:
  using Callback = std::function<void(const Value&)>;

  /// Parses `source`. Throws ParseError on a syntax error or unknown builtin.
  static Filter compile(std::string_view source);

  /// Evaluates the filter on `input`, calling `emit` for every output in
  /// order. If evaluation raises an error, the outputs produced before it
  /// have already been delivered and RuntimeError is thrown. An exception
  /// thrown by `emit` propagates unchanged (and is never swallowed by `?`).
  void run(const Value& input, const Callback& emit) const;

  /// All outputs of the filter on `input`. If an error occurs, RuntimeError
  /// is thrown and the partial results are lost; use `run` to keep them.
  std::vector<Value> collect(const Value& input) const;

 private:
  struct Impl;
  std::shared_ptr<const Impl> impl_;
};

/// Convenience: parse `json`, run `filter` on it and return every output as
/// compact JSON text. Throws ParseError, JsonError or RuntimeError.
std::vector<std::string> evaluate(std::string_view filter, std::string_view json);

}  // namespace jq
