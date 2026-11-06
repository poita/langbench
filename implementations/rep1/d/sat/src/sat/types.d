/// Literal and truth-value encoding shared by the solver modules.
module sat.types;

/// A variable index, 0-based.
alias Var = int;

/// An internal literal: variable `v` is `2v` (positive) or `2v + 1` (negated).
alias Lit = int;

/// Truth value of a literal in the current partial assignment.
enum ubyte lUndef = 0;
/// ditto
enum ubyte lTrue = 1;
/// ditto
enum ubyte lFalse = 2;

pure nothrow @safe @nogc:

/// Build the internal literal for variable `v` (0-based) with the given sign.
Lit mkLit(Var v, bool negated = false)
{
    return 2 * v + (negated ? 1 : 0);
}

/// The variable of a literal.
Var var(Lit l)
{
    return l >> 1;
}

/// Whether the literal is the negative occurrence of its variable.
bool sign(Lit l)
{
    return (l & 1) != 0;
}

/// Negation of a literal.
Lit neg(Lit l)
{
    return l ^ 1;
}

/// Convert a non-zero DIMACS literal (`k` or `-k`, 1-based) to an internal literal.
Lit fromDimacs(int d)
{
    return d > 0 ? 2 * (d - 1) : 2 * (-d - 1) + 1;
}

/// Convert an internal literal to its DIMACS form.
int toDimacs(Lit l)
{
    return sign(l) ? -(var(l) + 1) : var(l) + 1;
}

unittest
{
    assert(fromDimacs(1) == 0 && fromDimacs(-1) == 1);
    assert(fromDimacs(3) == 4 && fromDimacs(-3) == 5);
    foreach (d; [-7, -1, 1, 2, 9])
        assert(toDimacs(fromDimacs(d)) == d);
    assert(neg(neg(6)) == 6 && neg(6) == 7);
}
