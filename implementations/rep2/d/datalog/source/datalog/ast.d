/// Syntax tree of a Datalog program.
///
/// Constants are interned in a `SymbolTable`; predicates (name + arity) are
/// interned in the `Program`. Everything in the tree refers to them by small
/// integer ids, so rules are cheap to copy and compare.
module datalog.ast;

import std.algorithm.comparison : cmp;
import std.algorithm.sorting : sort;
import std.conv : to;

/// Id of an interned constant (an integer or an identifier).
alias SymbolId = uint;

/// Id of a predicate, i.e. of a (name, arity) pair.
alias PredId = uint;

/// Interns constants and defines the total order on them.
///
/// Integers sort before identifiers; integers compare numerically and
/// identifiers by byte value (`strcmp` order).
final class SymbolTable
{
    private struct Entry
    {
        bool isInt;
        long number;
        string name;
    }

    private Entry[] entries;
    private SymbolId[long] intIds;
    private SymbolId[string] nameIds;

    /// Number of distinct constants interned so far.
    @property size_t length() const @safe pure nothrow @nogc
    {
        return entries.length;
    }

    /// Interns an integer constant.
    SymbolId internInt(long value) @safe pure nothrow
    {
        if (auto p = value in intIds)
            return *p;
        auto id = cast(SymbolId) entries.length;
        entries ~= Entry(true, value, null);
        intIds[value] = id;
        return id;
    }

    /// Interns an identifier constant.
    SymbolId internName(string name) @safe pure nothrow
    {
        if (auto p = name in nameIds)
            return *p;
        auto id = cast(SymbolId) entries.length;
        entries ~= Entry(false, 0, name);
        nameIds[name] = id;
        return id;
    }

    /// The text of a constant as it appears in the program and in answers.
    string text(SymbolId id) const @safe pure
    {
        auto e = entries[id];
        return e.isInt ? e.number.to!string : e.name;
    }

    /// Three-way comparison of two constants in the total order.
    int compare(SymbolId a, SymbolId b) const @safe pure
    {
        auto x = entries[a], y = entries[b];
        if (x.isInt != y.isInt)
            return x.isInt ? -1 : 1;
        if (x.isInt)
            return x.number < y.number ? -1 : (x.number > y.number ? 1 : 0);
        return cmp(x.name, y.name);
    }

    /// All symbol ids sorted ascending in the total order.
    SymbolId[] sortedIds() const @safe pure
    {
        auto ids = new SymbolId[entries.length];
        foreach (i, ref id; ids)
            id = cast(SymbolId) i;
        ids.sort!((a, b) => compare(a, b) < 0);
        return ids;
    }
}

/// A term is a constant or a variable.
struct Term
{
    /// Whether `id` is a symbol id or a clause-local variable index.
    bool isVariable;
    /// Symbol id (constants) or variable index (variables).
    uint id;

    static Term constant(SymbolId s) @safe pure nothrow @nogc
    {
        return Term(false, s);
    }

    static Term variable(uint index) @safe pure nothrow @nogc
    {
        return Term(true, index);
    }
}

/// `pred(arg, ...)`.
struct Atom
{
    PredId pred;
    Term[] args;
}

/// Comparison built-ins.
enum CmpOp : ubyte
{
    lt, le, gt, ge, eq, ne
}

/// The three kinds of body literal.
enum LiteralKind : ubyte
{
    positive, negative, comparison
}

/// A body literal: an atom (positive or negated) or a comparison `lhs op rhs`.
struct Literal
{
    LiteralKind kind;
    Atom atom; /// for `positive` and `negative`
    Term lhs, rhs; /// for `comparison`
    CmpOp op; /// for `comparison`
}

/// `head :- body.`; a fact has an empty body.
///
/// Every `_` is turned into a fresh variable, so `numVars` counts them too.
struct Rule
{
    Atom head;
    Literal[] body;
    uint numVars;
}

/// `?- atom.`
struct Query
{
    Atom atom;
    uint numVars;
}

/// Name and arity of a predicate.
struct PredicateInfo
{
    string name;
    uint arity;
}

/// A parsed program: its rules (facts included), queries and symbol tables.
final class Program
{
    SymbolTable symbols;
    PredicateInfo[] predicates;
    Rule[] rules;
    Query[] queries;
    private PredId[string] predIds;

    this() @safe pure nothrow
    {
        symbols = new SymbolTable;
    }

    /// Interns the predicate `name/arity`.
    PredId predicate(string name, uint arity) @safe pure
    {
        auto key = name ~ "/" ~ arity.to!string;
        if (auto p = key in predIds)
            return *p;
        auto id = cast(PredId) predicates.length;
        predicates ~= PredicateInfo(name, arity);
        predIds[key] = id;
        return id;
    }

    /// Looks up `name/arity`; returns false when the program never mentions it.
    bool findPredicate(string name, uint arity, out PredId id) const @safe pure
    {
        if (auto p = (name ~ "/" ~ arity.to!string) in predIds)
        {
            id = *p;
            return true;
        }
        return false;
    }
}
