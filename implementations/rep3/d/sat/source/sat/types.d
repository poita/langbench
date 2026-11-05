/**
 * Basic types shared by the solver modules: the internal literal encoding.
 *
 * Variables are numbered from 0 internally. Variable `v` has two literals:
 * `2*v` (the variable is true) and `2*v + 1` (the variable is false), so
 * negation is `lit ^ 1`. DIMACS literals (`k` / `-k`, 1-based) are converted
 * with $(LREF fromDimacs) and $(LREF toDimacs).
 */
module sat.types;

@safe pure nothrow @nogc:

/// An internal literal (see the module description for the encoding).
alias Lit = int;

/// Index of a clause inside the solver's clause storage.
alias ClauseRef = int;

/// Marker meaning "no clause" (used for decisions and unit facts).
enum ClauseRef noClause = -1;

/// Internal literal for a non-zero DIMACS literal.
Lit fromDimacs(int d)
{
    assert(d != 0, "0 is not a literal");
    return d > 0 ? 2 * (d - 1) : 2 * (-d - 1) + 1;
}

/// DIMACS literal for an internal literal.
int toDimacs(Lit l)
{
    immutable v = (l >> 1) + 1;
    return (l & 1) ? -v : v;
}

/// 0-based variable of a literal.
int var(Lit l) { return l >> 1; }

/// The complementary literal.
Lit neg(Lit l) { return l ^ 1; }

/// Literal of variable `v` (0-based) with the given sign.
Lit mkLit(int v, bool positive) { return 2 * v + (positive ? 0 : 1); }
