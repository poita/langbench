// Dense encoding of constants as machine integers.
#pragma once

#include <cstdint>
#include <optional>
#include <string>
#include <vector>

#include "datalog/ast.h"

namespace datalog {

/// An encoded constant. The encoding preserves the constant order, so
/// comparing two Values with the built-in operators compares the constants.
using Value = std::int64_t;

/// Maps constants to Values and back. Integers encode as themselves;
/// symbols encode as `kSymbolBase + rank` where rank is the symbol's
/// position in the sorted set of all symbols of the program.
class ValueEncoder {
 public:
  /// Integers in programs have magnitude <= 1e9; any integer below this
  /// base is representable.
  static constexpr Value kSymbolBase = Value{1} << 40;

  /// Builds an encoder for every symbol occurring in `program`.
  static ValueEncoder of(const Program& program);

  /// Encodes `c`; returns nullopt for a symbol not in the program.
  std::optional<Value> encode(const Constant& c) const;
  Constant decode(Value v) const;
  /// Text of an encoded constant.
  std::string text(Value v) const;

 private:
  std::vector<std::string> symbols_;  // sorted, unique
};

}  // namespace datalog
