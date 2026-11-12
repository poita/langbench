/**
 * Type representation.
 *
 * Types form a shared graph. A type variable is a union-find node: it is
 * either unbound or `link`ed to another type, and carries a `level` used for
 * Rémy-style generalisation. Constructed types (functions, tuples, lists)
 * refer to their component types and may be shared freely.
 */
module typeinfer.types;

/// The shape of a $(LREF Type) node.
enum Kind : ubyte
{
    int_, bool_, unit, fun, tuple, list, var,
}

/// Level of a quantified (generalised) variable.
enum int genericLevel = int.max;

/**
 * A node of the type graph.
 *
 * Nodes are mutated by unification, so share them only within one
 * $(REF Solver, typeinfer.solver). The fields other than `kind` and `args`
 * are bookkeeping for the algorithms and are not part of the public contract.
 */
final class Type
{
    /// Shape of this node.
    Kind kind;
    /// For variables: nesting depth of the `let` that owns it (or `genericLevel`).
    int level;
    /// Walk marker used by the algorithms in `solver` to visit each node once.
    uint stamp;
    /// For variables: the type this one was bound to. For merged constructed types: the representative.
    Type link;
    /// Scratch slot for instantiation.
    Type copy;
    /// Components: 2 for `fun` (argument, result), n for `tuple`, 1 for `list`, none otherwise.
    Type[] args;

    private this(Kind kind, int level, Type[] args) @safe nothrow @nogc
    {
        this.kind = kind;
        this.level = level;
        this.args = args;
    }

    /// `int`, `bool` and `unit` are immutable singletons.
    static Type int_() @trusted nothrow @nogc { return intType; }
    /// ditto
    static Type bool_() @trusted nothrow @nogc { return boolType; }
    /// ditto
    static Type unit() @trusted nothrow @nogc { return unitType; }

    /// A fresh unbound variable at `level`.
    static Type newVar(int level) @safe nothrow { return new Type(Kind.var, level, null); }

    /// `arg -> result`.
    static Type fun(Type arg, Type result) @safe nothrow { return new Type(Kind.fun, 0, [arg, result]); }

    /// `elem list`.
    static Type list(Type elem) @safe nothrow { return new Type(Kind.list, 0, [elem]); }

    /// `t1 * ... * tn`; `elems` must have at least two elements.
    static Type tuple(Type[] elems) @safe nothrow
    in (elems.length >= 2)
    {
        return new Type(Kind.tuple, 0, elems);
    }

    /// Whether this node is a leaf constructor (`int`, `bool`, `unit`).
    bool isBase() const @safe nothrow @nogc { return kind <= Kind.unit; }

    private static Type mkBase(Kind k) { return new Type(k, 0, null); }
}

private __gshared Type intType, boolType, unitType;

shared static this()
{
    intType = Type.mkBase(Kind.int_);
    boolType = Type.mkBase(Kind.bool_);
    unitType = Type.mkBase(Kind.unit);
}

/// Follows variable (and merge) links to the representative node, compressing the path.
Type prune(Type t) @safe nothrow @nogc
{
    if (t.link is null) return t;
    Type r = t.link;
    while (r.link !is null) r = r.link;
    while (t !is r)
    {
        auto n = t.link;
        t.link = r;
        t = n;
    }
    return r;
}

unittest
{
    auto a = Type.newVar(0), b = Type.newVar(0), c = Type.newVar(0);
    a.link = b;
    b.link = c;
    assert(prune(a) is c && a.link is c);
    assert(prune(c) is c);
    assert(Type.int_ is Type.int_ && Type.int_ !is Type.bool_);
}
