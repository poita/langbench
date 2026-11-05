/// The filter syntax tree.
module jq.ast;

import jq.value;

/// Node kinds.
enum K : ubyte
{
    identity, literal, variable,
    field, index, slice, iterate, tryOp,
    neg, bin, and, or, comma, pipe,
    array, object, ifOp, asOp, reduce, call,
}

/// Binary operators.
enum BinOp : ubyte { add, sub, mul, div, mod, eq, ne, lt, le, gt, ge }

/// Builtin functions.
enum B : ubyte
{
    empty, error, not, length, keys, has, type, add, select, map, sort,
    sortBy, groupBy, unique, reverse, min, max, tostring, tonumber,
}

/// One `{...}` entry.
struct ObjEntry
{
    Node keyExpr; // computed key, or null when `keyLit` is used
    string keyLit;
    Node val;
}

/// A syntax-tree node. Only the fields relevant to `kind` are used.
final class Node
{
    K kind;
    BinOp op;
    B builtin;
    bool opt; // path operation with `?` (errors skip the combination)
    bool simple; // always exactly one output (or an error): no generator needed
    bool litDistinct; // object construction with distinct literal keys
    int id; // variable id
    string str; // field name / variable name
    Value lit;
    Node a, b, c; // children (meaning depends on `kind`)
    Node[] args; // builtin arguments
    ObjEntry[] entries;

    this(K k)
    {
        kind = k;
    }
}

/// A compiled filter.
final class Program
{
    Node root;
    this(Node r)
    {
        root = r;
    }
}
