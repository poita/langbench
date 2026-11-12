/// \file numeric.hpp
/// Integer arithmetic on Values. Integers are 64-bit "fixnums" when they fit
/// and BigIntObjects otherwise; results are always normalised back to fixnums
/// when they fit.
#pragma once

#include <string>
#include <string_view>

#include "scheme/value.hpp"

namespace scheme::num {

/// Normalise: a fixnum when the value fits in 64 bits, else a heap bignum.
Value from_bigint(BigInt v);
BigInt to_bigint(const Value& v);
/// Parse `[+-]?[0-9]+` of any length.
Value parse(std::string_view digits);
std::string to_string(const Value& v);

Value add(const Value& a, const Value& b);
Value sub(const Value& a, const Value& b);
Value mul(const Value& a, const Value& b);
Value negate(const Value& a);
/// Truncating division; `b` must be nonzero.
Value quotient(const Value& a, const Value& b);
Value remainder(const Value& a, const Value& b);
bool is_zero(const Value& a);
/// -1, 0 or 1.
int compare(const Value& a, const Value& b);

}  // namespace scheme::num
