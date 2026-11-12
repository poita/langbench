/// Literal encoding shared by the solver modules.
module sat.types;

/**
 * An internal literal. Variable `v` (0-based) has the positive literal `2*v`
 * and the negative literal `2*v + 1`, so negation is a flip of the low bit and
 * a literal can index arrays directly.
 */
alias Lit = int;

/// Marker for "no literal".
enum Lit litUndef = -1;

/// Builds the literal of 0-based variable `variable`; `negated` selects the negative one.
Lit mkLit(int variable, bool negated = false) pure nothrow @nogc @safe
{
    return 2 * variable + (negated ? 1 : 0);
}

/// The 0-based variable of a literal.
int variableOf(Lit l) pure nothrow @nogc @safe { return l >> 1; }

/// True if the literal is a negative one.
bool isNegative(Lit l) pure nothrow @nogc @safe { return (l & 1) != 0; }

/// The complementary literal.
Lit negate(Lit l) pure nothrow @nogc @safe { return l ^ 1; }

/// Converts a non-zero DIMACS integer (`k` or `-k`, `k >= 1`) to an internal literal.
Lit fromDimacs(int d) pure nothrow @nogc @safe
in (d != 0)
{
    return d > 0 ? mkLit(d - 1) : mkLit(-d - 1, true);
}

/// Converts an internal literal back to its DIMACS integer.
int toDimacs(Lit l) pure nothrow @nogc @safe
{
    immutable v = variableOf(l) + 1;
    return isNegative(l) ? -v : v;
}

///
@safe pure nothrow @nogc unittest
{
    assert(fromDimacs(1) == 0);
    assert(fromDimacs(-1) == 1);
    assert(fromDimacs(3) == mkLit(2));
    assert(negate(fromDimacs(3)) == fromDimacs(-3));
    foreach (d; [-7, -1, 1, 2, 100])
        assert(toDimacs(fromDimacs(d)) == d);
    assert(variableOf(fromDimacs(-5)) == 4);
    assert(isNegative(fromDimacs(-5)) && !isNegative(fromDimacs(5)));
}
