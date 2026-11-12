// Basic value types shared by the whole library: variables, literals and
// three-valued truth values.
#pragma once

#include <cstdlib>

namespace sat {

/// A propositional variable, numbered from 0 internally.
/// (DIMACS variable k corresponds to Var k - 1.)
using Var = int;

/// A literal: a variable or its negation. Packed as 2*var + (negated ? 1 : 0)
/// so that it can index arrays directly.
class Lit {
 public:
  constexpr Lit() : x_(-2) {}
  constexpr Lit(Var v, bool negated) : x_(2 * v + (negated ? 1 : 0)) {}

  /// Build from a non-zero DIMACS integer: 3 is "variable 3 is true",
  /// -3 is "variable 3 is false".
  static constexpr Lit fromDimacs(int d) {
    return d > 0 ? Lit(d - 1, false) : Lit(-d - 1, true);
  }

  /// The DIMACS integer for this literal (inverse of fromDimacs).
  constexpr int toDimacs() const { return negated() ? -(var() + 1) : var() + 1; }

  constexpr Var var() const { return x_ >> 1; }
  constexpr bool negated() const { return (x_ & 1) != 0; }
  /// Dense index in [0, 2 * numVars), for array lookups.
  constexpr int index() const { return x_; }

  constexpr Lit operator~() const {
    Lit l;
    l.x_ = x_ ^ 1;
    return l;
  }
  constexpr bool operator==(Lit o) const { return x_ == o.x_; }
  constexpr bool operator!=(Lit o) const { return x_ != o.x_; }
  constexpr bool operator<(Lit o) const { return x_ < o.x_; }

 private:
  int x_;
};

/// Three-valued truth value of a variable or literal.
enum class LBool : signed char { False = -1, Undef = 0, True = 1 };

/// Negate `b` when `flip` is true.
constexpr LBool flipIf(LBool b, bool flip) {
  return flip ? static_cast<LBool>(-static_cast<int>(b)) : b;
}

}  // namespace sat
