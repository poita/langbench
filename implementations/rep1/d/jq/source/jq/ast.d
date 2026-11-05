/**
 * Abstract syntax tree of a compiled filter.
 */
module jq.ast;

import jq.ops : BinOp;
import jq.value;

/// Node kinds.
enum Kind : ubyte
{
    identity, literal, variable,
    field, index, slice, iterate, tryOp,
    pipe, comma, binop, and, or, neg,
    arrayCons, objCons, ifOp, asOp, reduce,
    // builtins
    empty, error, errorOf, not, length, keys, has, type, add,
    select, map, sort, sortBy, groupBy, unique, reverse, min, max,
    toStringOp, toNumberOp,
}

/// One AST node. Which fields are used depends on `kind` (see comments).
final class Node
{
    Kind kind;
    /// Operator for `binop`.
    BinOp op;
    /// `?`-tolerant flag for `field`, `index`, `slice`, `iterate`.
    bool opt;
    /// True when the node yields exactly one output (or raises an error) for any input.
    bool single;
    /// Operands: term / lhs / condition / source, etc. (see parser for each kind).
    Node a, b, c;
    /// Constant for `literal`.
    Value lit;
    /// Literal key for `field`.
    JStr key;
    /// Variable id for `variable`, `asOp`, `reduce`.
    int varId;
    /// Keys and values of `objCons` entries.
    Node[] ks, vs;
    /// True if every `objCons` key is a distinct literal.
    bool distinctLiteralKeys;
    /// The shared key array when `distinctLiteralKeys` (never mutated).
    JStr[] litKeys;

    this(Kind k) pure nothrow @safe @nogc { kind = k; }
}
