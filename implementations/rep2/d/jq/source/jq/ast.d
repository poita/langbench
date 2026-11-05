/**
 * Abstract syntax tree of a jq filter.
 *
 * Nodes are plain `Node` objects tagged with a $(LREF NodeKind); the meaning of
 * the generic child fields `a`, `b` and `c` is documented per kind below.
 */
module jq.ast;

import jq.value;

/// What a $(LREF Node) is.
enum NodeKind : ubyte
{
    identity, /// `.`
    literal, /// constant in `lit`
    variable, /// `$x`; `depth` = number of bindings between use and definition
    field, /// `a.name` (`name` is the key); `opt` for `.name?`
    index, /// `a[b]`; `opt` for `?`
    slice, /// `a[b:c]`; `b` / `c` may be null; `opt` for `?`
    iterate, /// `a[]`; `opt` for `?`
    tryOp, /// `try a` (the postfix `?` after a non-path term)
    neg, /// `-a`
    binary, /// `a op b` with `op` an arithmetic or comparison operator
    and, /// `a and b`
    or, /// `a or b`
    pipe, /// `a | b`
    comma, /// `a , b`
    collect, /// `[a]`; `a` null for `[]`
    object, /// `{...}`, see `entries`
    ifElse, /// `if a then b else c end` (`c` is never null)
    asBind, /// `a as $x | b`
    reduce, /// `reduce a as $x (b; c)`
    call, /// builtin `fn` with `args`
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

/// Builtin functions.
enum Builtin : ubyte
{
    empty,
    error,
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

/// One entry of an object construction.
struct ObjEntry
{
    /// Computed key expression, or null if the key is the literal `litKey`.
    Node key;
    JStr litKey;
    /// The value expression.
    Node val;
}

/// An AST node.
final class Node
{
    NodeKind kind;
    /// True if the node always yields exactly one output or an error and
    /// needs no generator machinery (set by $(LREF finish)).
    bool simple;
    /// Path suffixes: errors of this one operation are skipped (`?`).
    bool opt;
    BinOp op;
    Builtin fn;
    Node a, b, c;
    Node[] args;
    Value lit;
    JStr name;
    int depth;
    ObjEntry[] entries;
    /// Object construction whose keys are all distinct literals.
    bool distinctLiteralKeys;

    this(NodeKind k)
    {
        kind = k;
    }
}

/// Builtins that take no arguments and produce exactly one output from `.`.
bool isPureNullary(Builtin f) pure nothrow @nogc @safe
{
    switch (f)
    {
    case Builtin.not:
    case Builtin.length:
    case Builtin.keys:
    case Builtin.type:
    case Builtin.add:
    case Builtin.sort:
    case Builtin.unique:
    case Builtin.reverse:
    case Builtin.min:
    case Builtin.max:
    case Builtin.tostring:
    case Builtin.tonumber:
        return true;
    default:
        return false;
    }
}

/// Compute the `simple` flag of a freshly built node (children must already be finished) and return it.
Node finish(Node n)
{
    static bool s(Node x)
    {
        return x !is null && x.simple;
    }

    final switch (n.kind)
    {
    case NodeKind.identity:
    case NodeKind.literal:
    case NodeKind.variable:
        n.simple = true;
        break;
    case NodeKind.field:
    case NodeKind.neg:
        n.simple = !n.opt && s(n.a);
        break;
    case NodeKind.index:
        n.simple = !n.opt && s(n.a) && s(n.b);
        break;
    case NodeKind.binary:
    case NodeKind.and:
    case NodeKind.or:
    case NodeKind.pipe:
        n.simple = s(n.a) && s(n.b);
        break;
    case NodeKind.ifElse:
        n.simple = s(n.a) && s(n.b) && s(n.c);
        break;
    case NodeKind.call:
        n.simple = n.args.length == 0 && isPureNullary(n.fn);
        break;
    case NodeKind.slice:
    case NodeKind.iterate:
    case NodeKind.tryOp:
    case NodeKind.comma:
    case NodeKind.collect:
    case NodeKind.object:
    case NodeKind.asBind:
    case NodeKind.reduce:
        n.simple = false;
        break;
    }
    return n;
}
