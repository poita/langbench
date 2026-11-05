/// Abstract syntax of a Datalog program, plus the symbol tables built while parsing.
module datalog.ast;

import std.conv : to;

/// Comparison operators usable in rule bodies.
enum CmpOp : ubyte
{
    lt,
    le,
    gt,
    ge,
    eq,
    ne
}

/// A term: either a clause-local variable slot or a constant id.
///
/// After `Program.canonicalize`, constant ids are ranks in the SPEC total order,
/// so comparing ids compares constants.
struct Term
{
    bool isVariable;
    uint id; /// variable slot, or constant id

    static Term variable(uint slot) pure nothrow @nogc @safe
    {
        return Term(true, slot);
    }

    static Term constant(uint id) pure nothrow @nogc @safe
    {
        return Term(false, id);
    }
}

/// `pred(args...)`; `pred` indexes `Program.predicates`.
struct Atom
{
    uint pred;
    Term[] args;
}

/// What a body literal is.
enum LiteralKind : ubyte
{
    positive, /// `p(...)`
    negative, /// `not p(...)`
    comparison /// `t1 op t2`
}

/// A body literal. `atom` is used for atoms; `op`, `lhs`, `rhs` for comparisons.
struct Literal
{
    LiteralKind kind;
    Atom atom;
    CmpOp op;
    Term lhs, rhs;
}

/// A rule `head :- body.`; a fact is a rule with an empty body.
struct Rule
{
    Atom head;
    Literal[] body;
    uint numVars; /// number of variable slots (including each `_`)

    bool isFact() const pure nothrow @nogc @safe
    {
        return body.length == 0;
    }
}

/// A query `?- atom.`
struct Query
{
    Atom atom;
    uint numVars;
}

/// A predicate is a name together with an arity.
struct Predicate
{
    string name;
    uint arity;
}

/// A constant: an integer or an identifier.
struct Constant
{
    bool isInteger;
    long value; /// valid when `isInteger`
    string name; /// valid when not `isInteger`

    /// The text used to print the constant.
    string text() const @safe
    {
        return isInteger ? value.to!string : name;
    }
}

/// Total order on constants: integers (numerically) before identifiers (bytewise).
int compareConstants(const Constant a, const Constant b) pure nothrow @nogc @safe
{
    if (a.isInteger != b.isInteger)
        return a.isInteger ? -1 : 1;
    if (a.isInteger)
        return a.value < b.value ? -1 : (a.value > b.value ? 1 : 0);
    // Byte-wise comparison with a proper prefix sorting first.
    foreach (i; 0 .. (a.name.length < b.name.length ? a.name.length : b.name.length))
        if (a.name[i] != b.name[i])
            return a.name[i] < b.name[i] ? -1 : 1;
    return a.name.length < b.name.length ? -1 : (a.name.length > b.name.length ? 1 : 0);
}

/// A parsed program: clauses plus interned predicates and constants.
final class Program
{
    Predicate[] predicates;
    Constant[] constants;
    Rule[] rules; /// facts and rules, in source order
    Query[] queries; /// in source order

    private uint[string] identifierIds;
    private uint[long] integerIds;
    private uint[string] predicateIds;
    private bool canonical_;
    private string[] texts;

    /// True once constant ids follow the total order of constants.
    bool isCanonical() const pure nothrow @nogc @safe
    {
        return canonical_;
    }

    /// Printed form of constant `id` (precomputed by `canonicalize`).
    string constantText(uint id) const pure nothrow @nogc @safe
    {
        return texts[id];
    }

    /// Intern an identifier constant, returning its id.
    uint internIdentifier(string name) @safe
    {
        assert(!canonical_);
        if (auto p = name in identifierIds)
            return *p;
        immutable id = cast(uint) constants.length;
        constants ~= Constant(false, 0, name);
        identifierIds[name] = id;
        return id;
    }

    /// Intern an integer constant, returning its id.
    uint internInteger(long value) @safe
    {
        assert(!canonical_);
        if (auto p = value in integerIds)
            return *p;
        immutable id = cast(uint) constants.length;
        constants ~= Constant(true, value, null);
        integerIds[value] = id;
        return id;
    }

    /// Intern the predicate `name/arity`, returning its id.
    uint internPredicate(string name, uint arity) @safe
    {
        immutable key = name ~ "/" ~ arity.to!string;
        if (auto p = key in predicateIds)
            return *p;
        immutable id = cast(uint) predicates.length;
        predicates ~= Predicate(name, arity);
        predicateIds[key] = id;
        return id;
    }

    /// Id of `name/arity` if the predicate exists.
    bool findPredicate(string name, uint arity, out uint id) const @safe
    {
        if (auto p = (name ~ "/" ~ arity.to!string) in predicateIds)
        {
            id = *p;
            return true;
        }
        return false;
    }

    /// Renumber constants so that id order is the total order of constants.
    /// Every term in every rule and query is rewritten. Idempotent.
    void canonicalize() @safe
    {
        import std.algorithm.sorting : sort;
        import std.range : iota;
        import std.array : array;

        if (canonical_)
            return;
        auto order = iota(cast(uint) constants.length).array;
        order.sort!((a, b) => compareConstants(constants[a], constants[b]) < 0);

        auto remap = new uint[constants.length];
        auto sorted = new Constant[constants.length];
        foreach (rank, old; order)
        {
            remap[old] = cast(uint) rank;
            sorted[rank] = constants[old];
        }
        constants = sorted;

        void fixTerm(ref Term t)
        {
            if (!t.isVariable)
                t.id = remap[t.id];
        }

        void fixAtom(ref Atom a)
        {
            foreach (ref t; a.args)
                fixTerm(t);
        }

        foreach (ref r; rules)
        {
            fixAtom(r.head);
            foreach (ref l; r.body)
            {
                fixAtom(l.atom);
                if (l.kind == LiteralKind.comparison)
                {
                    fixTerm(l.lhs);
                    fixTerm(l.rhs);
                }
            }
        }
        foreach (ref q; queries)
            fixAtom(q.atom);

        identifierIds = null;
        integerIds = null;
        foreach (i, c; constants)
        {
            if (c.isInteger)
                integerIds[c.value] = cast(uint) i;
            else
                identifierIds[c.name] = cast(uint) i;
        }
        texts = null;
        foreach (c; constants)
            texts ~= c.text;
        canonical_ = true;
    }
}
