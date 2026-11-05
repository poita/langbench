/**
 * Abstract syntax of Datalog programs and the symbol tables that go with it.
 *
 * Predicates and constants are interned to dense integer ids while a program is
 * built. After parsing, `Program.sortConstants` renumbers the constants so that
 * the numeric order of ids is the language's total order on constants (integers
 * first, numerically, then identifiers bytewise); from then on constants can be
 * compared and sorted as plain integers.
 */
module datalog.ast;

import std.conv : to;

/// Comparison operators usable in rule bodies.
enum CmpOp : ubyte
{
    lt, /// `<`
    le, /// `<=`
    gt, /// `>`
    ge, /// `>=`
    eq, /// `=`
    ne, /// `!=`
}

/// Evaluates `a op b` on two constant ids (valid once constants are sorted).
bool compare(CmpOp op, uint a, uint b) pure nothrow @nogc @safe
{
    final switch (op)
    {
    case CmpOp.lt: return a < b;
    case CmpOp.le: return a <= b;
    case CmpOp.gt: return a > b;
    case CmpOp.ge: return a >= b;
    case CmpOp.eq: return a == b;
    case CmpOp.ne: return a != b;
    }
}

/// The kinds of body literal.
enum LiteralKind : ubyte
{
    positive,   /// `p(...)`
    negative,   /// `not p(...)`
    comparison, /// `t1 op t2`
}

/// A term: either a variable (a per-clause slot number) or a constant id.
struct Term
{
    bool isVar;
    uint id; /// variable slot if `isVar`, otherwise constant id

    static Term var(uint slot) pure nothrow @nogc @safe { return Term(true, slot); }
    static Term constant(uint id) pure nothrow @nogc @safe { return Term(false, id); }
}

/// A predicate applied to terms. `predicate` is an id into `Program.predicates`.
struct Atom
{
    uint predicate;
    Term[] args;
}

/// A body literal. Only the fields relevant to `kind` are meaningful.
struct Literal
{
    LiteralKind kind;
    Atom atom;   /// for `positive` / `negative`
    CmpOp op;    /// for `comparison`
    Term lhs;    /// for `comparison`
    Term rhs;    /// for `comparison`
}

/// A rule; a fact is a rule with an empty body.
struct Rule
{
    Atom head;
    Literal[] body;
    uint numVars; /// number of variable slots (every `_` has its own slot)

    bool isFact() const pure nothrow @nogc @safe { return body.length == 0; }
}

/// A query `?- atom.`
struct Query
{
    Atom atom;
    uint numVars;
}

/// A predicate symbol: name and arity together identify a predicate.
struct Predicate
{
    string name;
    uint arity;
}

/// A constant: an integer or an identifier.
struct Constant
{
    bool isInt;
    long number;  /// valid if `isInt`
    string name;  /// valid if `!isInt`

    /// The constant as it is printed.
    string text() const
    {
        return isInt ? number.to!string : name;
    }

    /// The total order on constants: integers (numerically) before identifiers (bytewise).
    int opCmp(const Constant o) const pure nothrow @nogc @safe
    {
        if (isInt != o.isInt)
            return isInt ? -1 : 1;
        if (isInt)
            return number < o.number ? -1 : (number > o.number ? 1 : 0);
        return name < o.name ? -1 : (name > o.name ? 1 : 0);
    }
}

/// A parsed program together with its symbol tables.
struct Program
{
    Rule[] rules;           /// all rules and facts, in source order
    Query[] queries;        /// queries, in source order
    Predicate[] predicates; /// indexed by predicate id
    Constant[] constants;   /// indexed by constant id

    private uint[string] predicateIds;
    private uint[long] intIds;
    private uint[string] nameIds;

    /// Interns the predicate `name/arity`.
    uint predicate(string name, uint arity)
    {
        const key = name ~ "/" ~ arity.to!string;
        if (auto p = key in predicateIds)
            return *p;
        const id = cast(uint) predicates.length;
        predicates ~= Predicate(name, arity);
        predicateIds[key] = id;
        return id;
    }

    /// Interns an integer constant.
    uint intConstant(long value)
    {
        if (auto p = value in intIds)
            return *p;
        const id = cast(uint) constants.length;
        constants ~= Constant(true, value, null);
        intIds[value] = id;
        return id;
    }

    /// Interns an identifier constant.
    uint nameConstant(string name)
    {
        if (auto p = name in nameIds)
            return *p;
        const id = cast(uint) constants.length;
        constants ~= Constant(false, 0, name);
        nameIds[name] = id;
        return id;
    }

    /**
     * Renumbers all constants so that id order equals constant order, rewriting
     * every constant occurrence in rules and queries. Idempotent.
     */
    void sortConstants()
    {
        import std.algorithm.sorting : sort;
        import std.range : iota;
        import std.array : array;

        auto order = iota(cast(uint) constants.length).array;
        order.sort!((a, b) => constants[a] < constants[b]);
        auto remap = new uint[constants.length];
        auto sorted = new Constant[constants.length];
        foreach (rank, old; order)
        {
            remap[old] = cast(uint) rank;
            sorted[rank] = constants[old];
        }
        void fix(Term[] ts)
        {
            foreach (ref t; ts)
                if (!t.isVar)
                    t.id = remap[t.id];
        }
        foreach (ref r; rules)
        {
            fix(r.head.args);
            foreach (ref l; r.body)
            {
                fix(l.atom.args);
                if (l.kind == LiteralKind.comparison)
                {
                    if (!l.lhs.isVar) l.lhs.id = remap[l.lhs.id];
                    if (!l.rhs.isVar) l.rhs.id = remap[l.rhs.id];
                }
            }
        }
        foreach (ref q; queries)
            fix(q.atom.args);
        constants = sorted;
        intIds = null;
        nameIds = null;
        foreach (i, ref c; constants)
        {
            if (c.isInt) intIds[c.number] = cast(uint) i;
            else nameIds[c.name] = cast(uint) i;
        }
    }
}
