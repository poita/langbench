// jq/filter.hpp -- compiling and running jq filters.
//
//   jq::Filter f = jq::Filter::compile(".users | map(.name)");
//   jq::Value doc = jq::parse_json(text);
//   for (const jq::Value& v : f.run_all(doc)) std::cout << jq::to_json(v) << "\n";
//
// A filter maps one input value to a lazily produced stream of outputs. The
// supported language is the subset described in the project README.
#pragma once

#include <functional>
#include <memory>
#include <string>
#include <string_view>
#include <vector>

#include "jq/error.hpp"
#include "jq/json.hpp"
#include "jq/value.hpp"

namespace jq {

namespace detail {
struct Node;
}

/// How a run ended.
struct RunStatus {
  /// False if evaluation raised an error that was not caught.
  bool ok = true;
  /// Description of the error when `ok` is false.
  std::string error;
};

/// A compiled filter. Cheap to copy (the syntax tree is shared and immutable).
/// A Filter may be run many times; concurrent runs on distinct threads are
/// fine as long as the Values involved are not shared between threads.
class Filter {
 public:
  /// Receives each output in order. Return false to stop evaluation early
  /// (that is not an error).
  using Sink = std::function<bool(const Value&)>;

  /// Parses `program`. Throws SyntaxError if it is not valid.
  static Filter compile(std::string_view program);

  /// Runs the filter on `input`, passing each output to `sink` as it is
  /// produced. Outputs produced before an error have already been delivered
  /// when the error is reported.
  RunStatus run(const Value& input, const Sink& sink) const;

  /// Runs the filter and collects all outputs. Throws EvalError if evaluation
  /// fails (the outputs produced before the error are discarded; use `run` to
  /// keep them).
  std::vector<Value> run_all(const Value& input) const;

 private:
  explicit Filter(std::shared_ptr<const detail::Node> root) : root_(std::move(root)) {}
  std::shared_ptr<const detail::Node> root_;
};

/// Convenience for the command-line contract: parses `document`, evaluates
/// `program` on it and returns every output as one compact-JSON line. If
/// evaluation fails, the outputs produced so far are followed by a line
/// `error`. Throws SyntaxError / JsonError for malformed program or document.
std::string run_to_text(std::string_view program, std::string_view document);

}  // namespace jq
