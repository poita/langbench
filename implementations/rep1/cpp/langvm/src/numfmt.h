// Number formatting and parsing for the standard library (SPEC.md 14.3, 15.2, 15.3).
#pragma once

#include <cstdint>
#include <string>

namespace langvm {

// showFloatAt: `digits` in 0..17 (not checked here).
std::string formatFloatFixed(double x, int digits);
// Digits 0-9 then lowercase a-z; the magnitude is taken as an unsigned value.
std::string formatIntRadix(int64_t x, int radix);
// parseInt / parseIntRadix: optional sign, digits valid for `radix`, no overflow.
bool parseIntText(const std::u32string& s, int radix, int64_t& out);
// parseFloat grammar of SPEC 15.3; correctly rounded.
bool parseFloatText(const std::u32string& s, double& out);

}  // namespace langvm
