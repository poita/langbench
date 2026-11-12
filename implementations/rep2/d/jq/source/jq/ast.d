/// Syntax tree of a filter program.
module jq.ast;

import jq.value : Value;

/// Binary operators with the "right operand is the outer loop" evaluation order.
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
    sortBy,
    groupBy,
    unique,
    reverse,
    min,
    max,
    tostring,
    tonumber,
}

/// Node kinds.
enum NodeKind : ubyte
{
    identity, /// `.`
    literal, /// constant `lit`
    variable, /// `$name`
    pipe, /// `a | b`
    comma, /// `a , b`
    binary, /// `a op b`
    and, /// `a and b`
    or, /// `a or b`
    neg, /// `-a`
    index, /// `a[b]` / `a.name`; `optional` marks `?` on this suffix
    slice, /// `a[b:c]` (b or c may be null); `optional` as above
    iterate, /// `a[]`; `optional` as above
    try_, /// `a?` as try
    array, /// `[a]` (a may be null)
    object, /// `{k: v, ...}` with `keys` and `values`
    if_, /// `if a then b else c end` (c may be null = identity)
    as, /// `a as $name | b`
    reduce, /// `reduce a as $name (b; c)`
    call, /// builtin `fn` applied to `args`
}

/// A node of the syntax tree. Which fields are used depends on `kind`.
final class Node
{
    NodeKind kind;
    BinOp op;
    Builtin fn;
    bool optional;
    Node a, b, c;
    Node[] args; /// builtin arguments
    Node[] keys; /// object entry keys
    Node[] values; /// object entry values
    string name; /// variable name
    Value lit; /// literal value

    this(NodeKind kind, Node a = null, Node b = null, Node c = null)
    {
        this.kind = kind;
        this.a = a;
        this.b = b;
        this.c = c;
    }
}
