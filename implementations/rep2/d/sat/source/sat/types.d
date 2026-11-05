/**
 * Literal and variable encoding shared by the whole library.
 *
 * Internally, variable `v` (0-based) is represented by two literals:
 * `2*v` (the variable is true) and `2*v + 1` (the variable is false).
 * Negating a literal is therefore a single xor with 1.
 *
 * The public API of $(MREF sat.solver) speaks DIMACS integers (1-based,
 * negative for negated); the helpers here convert between the two views.
 */
module sat.types;

/// Internal literal: `2*var` for positive, `2*var + 1` for negative.
alias Lit = int;

/// Sentinel meaning "no literal".
enum Lit litUndef = -1;

/// Builds the internal literal for 0-based variable `var`.
Lit mkLit(int var, bool negated = false) pure nothrow @nogc @safe
{
    return 2 * var + (negated ? 1 : 0);
}

/// Negation of a literal.
Lit neg(Lit l) pure nothrow @nogc @safe
{
    return l ^ 1;
}

/// The 0-based variable of a literal.
int varOf(Lit l) pure nothrow @nogc @safe
{
    return l >> 1;
}

/// Whether the literal is the negative one of its variable.
bool isNeg(Lit l) pure nothrow @nogc @safe
{
    return (l & 1) != 0;
}

/// Converts a non-zero DIMACS integer to an internal literal.
Lit fromDimacs(int d) pure nothrow @nogc @safe
in (d != 0)
{
    return d > 0 ? mkLit(d - 1) : mkLit(-d - 1, true);
}

/// Converts an internal literal to its DIMACS integer.
int toDimacs(Lit l) pure nothrow @nogc @safe
{
    const v = varOf(l) + 1;
    return isNeg(l) ? -v : v;
}
