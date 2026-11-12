/// Basic value types shared by the solver modules.
module sat.types;

/// Three-valued truth value.
enum LBool : ubyte
{
    False = 0,
    True = 1,
    Undef = 2,
}

/**
 * A literal over a zero-based variable index.
 *
 * Encoded as `2 * var + sign`, where `sign` is 1 for a negative literal, so
 * that the literal can index arrays directly and negation is a bit flip.
 */
struct Lit
{
    /// The raw encoding.
    uint x = uint.max;

    /// Literal of variable `var` (zero-based); negative if `negative`.
    static Lit make(int var, bool negative = false) pure nothrow @nogc @safe
    {
        return Lit(cast(uint)(2 * var + (negative ? 1 : 0)));
    }

    /// Converts a non-zero DIMACS literal (`k` or `-k`, `k >= 1`) to a `Lit`.
    static Lit fromDimacs(int d) pure nothrow @nogc @safe
    in (d != 0)
    {
        return d > 0 ? make(d - 1, false) : make(-d - 1, true);
    }

    /// The DIMACS representation: variable index plus one, negated if negative.
    int toDimacs() const pure nothrow @nogc @safe
    {
        const v = var + 1;
        return sign ? -v : v;
    }

    /// Zero-based variable index.
    int var() const pure nothrow @nogc @safe { return cast(int)(x >> 1); }

    /// True if the literal is negative.
    bool sign() const pure nothrow @nogc @safe { return (x & 1) != 0; }

    /// Negation (`~lit`).
    Lit opUnary(string op : "~")() const pure nothrow @nogc @safe
    {
        return Lit(x ^ 1);
    }

    /// True for the distinguished "undefined" literal.
    bool isUndef() const pure nothrow @nogc @safe { return x == uint.max; }
}

/// The distinguished "no literal" value.
enum Lit litUndef = Lit(uint.max);

@safe pure nothrow @nogc unittest
{
    const a = Lit.make(3);
    assert(a.var == 3 && !a.sign);
    assert((~a).var == 3 && (~a).sign);
    assert(~~a == a);
    assert(a.toDimacs == 4 && (~a).toDimacs == -4);
    assert(Lit.fromDimacs(4) == a);
    assert(Lit.fromDimacs(-4) == ~a);
    assert(litUndef.isUndef && !a.isUndef);
}
