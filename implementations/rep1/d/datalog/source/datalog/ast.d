/// Abstract syntax of a Datalog program.
module datalog.ast;

import datalog.symbols;

/// Whether a term is a constant or a variable.
enum TermKind : ubyte
{
    constant,
    variable,
}

/// An argument of an atom.
///
/// For a constant, `id` is the constant's id in the program's `SymbolTable`;
/// for a variable it is the variable's slot number within its clause. Every
/// anonymous variable `_` gets a slot of its own.
struct Term
{
    TermKind kind;
    uint id;
}

/// A predicate: a name together with an arity.
struct Predicate
{
    string name;
    uint arity;
}

/// `name(args...)`; `predicate` indexes `Program.predicates`.
struct Atom
{
    uint predicate;
    Term[] args;
}

/// The three forms of body literal.
enum LiteralKind : ubyte
{
    positive,
    negated,
    comparison,
}

/// Comparison operators.
enum CmpOp : ubyte
{
    lt,
    le,
    gt,
    ge,
    eq,
    ne,
}

/// A body literal: an atom (positive or negated) or a comparison.
struct Literal
{
    LiteralKind kind;
    Atom atom; /// for `positive` and `negated`
    CmpOp op; /// for `comparison`
    Term lhs; /// for `comparison`
    Term rhs; /// for `comparison`
}

/// `head :- body.`; a fact has an empty body.
struct Rule
{
    Atom head;
    Literal[] body;
    uint numVars; /// number of variable slots in the clause
}

/// `?- atom.`
struct Query
{
    Atom atom;
    uint numVars;
}

/// A parsed program.
final class Program
{
    SymbolTable symbols;
    Predicate[] predicates;
    Rule[] rules; /// facts and rules in source order
    Query[] queries; /// in source order

    private uint[PredicateKey] predicateIds;

    private struct PredicateKey
    {
        string name;
        uint arity;
    }

    this() @safe pure nothrow
    {
        symbols = new SymbolTable;
    }

    /// Id of the predicate `name/arity`, registering it if new.
    uint predicateId(string name, uint arity) @safe pure
    {
        auto key = PredicateKey(name, arity);
        if (auto p = key in predicateIds)
            return *p;
        immutable id = cast(uint) predicates.length;
        predicateIds[key] = id;
        predicates ~= Predicate(name, arity);
        return id;
    }
}
