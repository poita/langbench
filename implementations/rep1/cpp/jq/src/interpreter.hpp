// Tree-walking evaluator (internal).
#pragma once

#include "ast.hpp"
#include "function_ref.hpp"
#include "jq/value.hpp"

namespace jq::detail {

using Emit = FunctionRef<void(const Value&)>;

/// Evaluates `root` on `input`, pushing every output to `out`.
/// Throws jq::RuntimeError when evaluation fails.
void evaluate(const Node& root, const Value& input, Emit out);

}  // namespace jq::detail
