// Basic value types shared by every module of the library.
#pragma once

#include <cstdint>
#include <functional>

namespace sat {

/// A propositional variable, numbered from 0 internally.
/// (DIMACS numbers variables from 1; see Lit::from_dimacs.)
using Var = int;

/// Sentinel for "no variable".
inline constexpr Var kVarUndef = -1;

/// A literal: a variable or its negation. Encoded as `2 * var + sign`, so a
/// literal doubles as a dense array index (see Lit::index()).
class Lit {
public:
    /// The undefined literal.
    constexpr Lit() : x_(-2) {}
    /// Literal of variable `v`; negated if `negative` is true.
    constexpr explicit Lit(Var v, bool negative = false) : x_(2 * v + (negative ? 1 : 0)) {}

    /// Converts a non-zero DIMACS integer (`k` or `-k`, k >= 1).
    static constexpr Lit from_dimacs(int d) { return d > 0 ? Lit(d - 1, false) : Lit(-d - 1, true); }

    constexpr Var var() const { return x_ >> 1; }
    constexpr bool negative() const { return (x_ & 1) != 0; }
    constexpr int index() const { return x_; }
    constexpr bool defined() const { return x_ >= 0; }
    /// The DIMACS integer for this literal.
    constexpr int to_dimacs() const { return negative() ? -(var() + 1) : var() + 1; }

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
enum class LBool : std::int8_t { False = 0, True = 1, Undef = 2 };

/// Outcome of Solver::solve().
enum class Result { Sat, Unsat };

}  // namespace sat
