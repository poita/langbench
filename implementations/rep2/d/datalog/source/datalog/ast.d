/// Data types describing a parsed Datalog program.
///
/// Constants are interned to dense integer ids. After parsing, ids are
/// *order-preserving*: comparing two constant ids as integers is the same as
/// comparing the constants in the language's total order (integers numerically,
/// before all identifiers, which compare bytewise).
module datalog.ast;

/// Dense id of an interned constant (its rank in the total order).
alias ConstId = uint;
/// Dense id of a predicate (a name together with an arity).
alias PredId = uint;

/// A term is either a constant or a variable slot (numbered per clause).
struct Term
{
    /// True if `id` is a variable slot, false if it is a `ConstId`.
    bool isVar;
    /// Constant id or variable slot.
    uint id;

    ///
    static Term constant(ConstId c) @safe pure nothrow @nogc { return Term(false, c); }
    ///
    static Term variable(uint slot) @safe pure nothrow @nogc { return Term(true, slot); }
}

/// Comparison operators usable as body literals.
enum CmpOp : ubyte
{
    lt, le, gt, ge, eq, ne
}

/// Evaluate `a op b` on two order-preserving constant ids.
bool compare(CmpOp op, uint a, uint b) @safe pure nothrow @nogc
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

/// A predicate applied to terms.
struct Atom
{
    PredId pred;
    Term[] args;
}

/// Kind of a body literal.
enum LiteralKind : ubyte
{
    positive,
    negative,
    comparison
}

/// A body literal: a positive atom, a negated atom, or a comparison `lhs op rhs`.
struct Literal
{
    LiteralKind kind;
    /// Used when `kind` is `positive` or `negative`.
    Atom atom;
    /// Used when `kind` is `comparison`.
    CmpOp op;
    Term lhs, rhs;
}

/// A rule `head :- body.`; a fact is a rule with an empty body.
struct Rule
{
    Atom head;
    Literal[] body;
    /// Number of distinct variable slots (including anonymous variables).
    uint numVars;

    /// True for a fact (empty body).
    bool isFact() const @safe pure nothrow @nogc { return body.length == 0; }
}

/// A query `?- atom.`
struct Query
{
    Atom atom;
    uint numVars;
}

/// A predicate symbol: name and arity identify it.
struct Predicate
{
    string name;
    uint arity;
}

/// A complete parsed program.
struct Program
{
    /// Text of every constant, indexed by `ConstId` (in total order).
    string[] constants;
    /// Every predicate mentioned anywhere, indexed by `PredId`.
    Predicate[] predicates;
    /// Facts and rules, in source order.
    Rule[] rules;
    /// Queries, in source order.
    Query[] queries;
}
