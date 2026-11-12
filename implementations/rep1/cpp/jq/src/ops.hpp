// Value-level operations used by the interpreter (internal).
#pragma once

#include <string>
#include <vector>

#include "ast.hpp"
#include "jq/value.hpp"

namespace jq::detail {

// Arithmetic and comparison. Throw jq::RuntimeError on type errors.
Value binary_op(BinOp op, const Value& a, const Value& b);
Value negate(const Value& v);

/// `t[k]`. Returns a pointer to the result (owned by `t` or static), or null
/// on a type error, in which case `*err` (if non-null) receives the message.
const Value* index_value(const Value& t, const Value& k, std::string* err);

/// `t[from:to]`; null bounds mean "absent". Returns false on a type error.
bool slice_value(const Value& t, const Value* from, const Value* to, Value& out,
                 std::string* err);

// Builtin helpers. Throw jq::RuntimeError on type errors.
Value builtin_length(const Value& v);
Value builtin_keys(const Value& v);
bool builtin_has(const Value& v, const Value& k);
Value builtin_add(const Value::Array& items);
Value builtin_reverse(const Value& v);
Value builtin_min_max(const Value& v, bool max);
Value builtin_tostring(const Value& v);
Value builtin_tonumber(const Value& v);
Value builtin_sort(const Value& v);
Value builtin_unique(const Value& v);

/// Stable sort of `items` by parallel `keys`; returns the permutation.
std::vector<std::size_t> sorted_permutation(const std::vector<Value>& keys);

}  // namespace jq::detail
