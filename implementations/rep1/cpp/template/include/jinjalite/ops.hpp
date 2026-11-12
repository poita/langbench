#pragma once
/// \file ops.hpp
/// Semantics of the operators on values: truthiness, arithmetic, comparison,
/// containment, attribute/subscript access and the sequence view.

#include "jinjalite/value.hpp"

namespace jinjalite {

enum class BinaryOp { Add, Sub, Mul, Div, FloorDiv, Mod, Pow, Concat };
enum class CompareOp { Eq, Ne, Lt, Le, Gt, Ge, In, NotIn };

/// Truthiness. Throws `Error(Undefined)` for the undefined value.
bool is_truthy(const Value& v);

/// Unary minus.
Value negate(const Value& v);

/// Applies an arithmetic or concatenation operator.
Value binary_op(BinaryOp op, const Value& lhs, const Value& rhs);

/// Applies a comparison or containment operator (undefined operands throw).
bool compare(CompareOp op, const Value& lhs, const Value& rhs);

/// `==` for two defined values; never throws.
bool values_equal(const Value& a, const Value& b);

/// `obj[key]` / `obj.key`: the member, element or character, or the
/// undefined value on a miss. Throws if `obj` or `key` is undefined.
Value get_item(const Value& obj, const Value& key);

/// The sequence view of a value (list, dict keys, string characters).
/// Throws `Error(Undefined)` for undefined and `Error(Type)` otherwise.
ListPtr sequence_view(const Value& v);

/// Throws `Error(Undefined)` if `v` is the undefined value.
void require_defined(const Value& v);

}  // namespace jinjalite
