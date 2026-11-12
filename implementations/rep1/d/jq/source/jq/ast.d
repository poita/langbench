/// The syntax tree of a compiled filter.
module jq.ast;

import jq.value;

/// Node kinds.
enum Op : ubyte
{
    identity, /// `.`
    literal, /// number, string, true, false, null
    field, /// `a.name`  (a = target, name)
    index, /// `a[b]`    (a = target, b = index)
    slice, /// `a[b:c]`  (a = target, b = from or null, c = to or null)
    iterate, /// `a[]`
    try_, /// `(a)?`
    pipe, /// `a | b`
    comma, /// `a, b`
    binop, /// `a op b`  (bop)
    and, /// `a and b`
    or, /// `a or b`
    neg, /// `-a`
    array, /// `[a]`  (a may be null)
    object, /// `{...}` (entries)
    if_, /// `if a then b else c end` (c may be null: identity)
    bind, /// `a as $v | b`
    reduce, /// `reduce a as $v (b; c)`
    var, /// `$v`
    call, /// builtin call (bi, args)
}

/// Binary operators.
enum BinOp : ubyte
{
    add,
    sub,
    mul,
    div,
    mod,
    eq,
    ne,
    lt,
    le,
    gt,
    ge,
}

/// Builtin functions of the supported subset.
enum Builtin : ubyte
{
    empty,
    error0,
    error1,
    not,
    length,
    keys,
    has,
    type,
    add,
    select,
    map,
    sort,
    sort_by,
    group_by,
    unique,
    reverse,
    min,
    max,
    tostring,
    tonumber,
}

/// One `key: value` entry of an object construction.
struct ObjEntry
{
    string litKey; /// the key when it is a literal
    Node keyExpr; /// the computed key `(expr)`, or null when `litKey` is used
    Node val; /// the value expression
}

/// A syntax tree node. All fields are set by the parser.
final class Node
{
    Op op;
    BinOp bop;
    Builtin bi;
    /// True for field/index/slice/iterate suffixes followed by `?`.
    bool opt;
    /// True when the node always yields exactly one output (or raises).
    bool single;
    Node a, b, c;
    Value lit;
    string name;
    int varId;
    ObjEntry[] entries;
    Node[] args;

    this(Op op)
    {
        this.op = op;
    }
}
