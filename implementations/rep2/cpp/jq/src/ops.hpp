// Internal: pure operations on values (arithmetic, indexing, builtins).
//
// Every fallible operation returns false on a type error and, when `err` is
// non-null, stores a message there. Passing nullptr avoids building the
// message, which is what callers do when the error will be discarded.
#pragma once

#include <string>
#include <string_view>
#include <vector>

#include "ast.hpp"
#include "jq/value.hpp"

namespace jq::detail {

bool binary_op(BinOp op, const Value& l, const Value& r, Value& out, std::string* err);

/// `t[k]` for a string or number key.
bool index_value(const Value& t, const Value& k, Value& out, std::string* err);

/// `t[from:to]`; null pointers mean an omitted bound.
bool slice_value(const Value& t, const Value* from, const Value* to, Value& out, std::string* err);

bool value_length(const Value& v, Value& out, std::string* err);
bool value_keys(const Value& v, Value& out, std::string* err);
bool value_has(const Value& v, const Value& k, bool& out, std::string* err);
bool value_add(const Value& v, Value& out, std::string* err);
bool value_reverse(const Value& v, Value& out, std::string* err);
bool value_min_max(const Value& v, bool want_max, Value& out, std::string* err);
bool value_tonumber(const Value& v, Value& out, std::string* err);
Value value_tostring(const Value& v);

/// Indices 0..keys.size()-1 stably sorted by `keys`.
std::vector<std::size_t> stable_order(const std::vector<Value>& keys);

bool value_sort(const Value& v, Value& out, std::string* err);
bool value_unique(const Value& v, Value& out, std::string* err);

/// Number of code points in UTF-8 text.
std::size_t utf8_length(const std::string& s);

}  // namespace jq::detail
