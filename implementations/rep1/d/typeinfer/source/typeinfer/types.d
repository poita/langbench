/**
 * Type terms: a shared, mutable graph of nodes stored in an arena.
 *
 * A type is identified by an `int` index into a `TypeStore`. A node is either
 * a type variable (unbound, or linked to another node by unification) or a
 * constructor (`int`, `bool`, `unit`, function, list, n-ary tuple). Sub-terms
 * are shared, never copied unless they must change.
 */
module typeinfer.types;

/// Index of a type node in a `TypeStore`.
alias TypeId = int;

/// Kind of a type node.
enum NodeKind : ubyte
{
    variable, /// unbound (`a < 0`) or linked to node `a`
    int_,     /// the type `int`
    bool_,    /// the type `bool`
    unit,     /// the type `unit`
    arrow,    /// `a -> b`
    list,     /// `a list`
    tuple,    /// `b` components at `pool[a .. a + b]`
}

/// Level value marking a quantified (generic) variable.
enum int genericLevel = int.max;

/// One node of the type graph.
struct Node
{
    /// Visit stamp: equal to a walk's stamp when the node was visited by it.
    ulong stamp;
    /// Variable: link target or -1. Arrow: parameter. List: element. Tuple: pool start.
    int a = -1;
    /// Arrow: result. Tuple: component count.
    int b;
    /// Variable: binding level (`genericLevel` once quantified).
    int level;
    /// Result slot of the walk that last stamped this node (instantiation copy or variable index).
    int memo;
    ///
    NodeKind kind;
}

/// Arena of type nodes plus the shared child pool for tuple components.
final class TypeStore
{
    /// The nodes; only the first `count` are in use.
    Node[] nodes;
    /// Number of nodes allocated.
    int count;
    /// Child pool for tuples.
    int[] pool;
    /// Number of pool entries in use.
    int poolCount;
    /// Counter handing out unique walk stamps (64 bits: never wraps).
    ulong lastStamp;

    /// Shared singleton `int`.
    enum TypeId intType = 0;
    /// Shared singleton `bool`.
    enum TypeId boolType = 1;
    /// Shared singleton `unit`.
    enum TypeId unitType = 2;

    ///
    this()
    {
        nodes = new Node[1024];
        pool = new int[256];
        alloc(NodeKind.int_);
        alloc(NodeKind.bool_);
        alloc(NodeKind.unit);
    }

    /// A fresh stamp, distinct from every earlier one.
    ulong newStamp() { return ++lastStamp; }

    private TypeId alloc(NodeKind kind)
    {
        if (count == nodes.length)
            nodes.length = nodes.length * 2;
        nodes[count] = Node.init;
        nodes[count].kind = kind;
        return count++;
    }

    /// A fresh unbound variable at `level`.
    TypeId newVar(int level)
    {
        immutable t = alloc(NodeKind.variable);
        nodes[t].level = level;
        return t;
    }

    /// The function type `param -> result`.
    TypeId newArrow(TypeId param, TypeId result)
    {
        immutable t = alloc(NodeKind.arrow);
        nodes[t].a = param;
        nodes[t].b = result;
        return t;
    }

    /// The type `element list`.
    TypeId newList(TypeId element)
    {
        immutable t = alloc(NodeKind.list);
        nodes[t].a = element;
        return t;
    }

    /// Reserves `n` pool slots and returns the index of the first.
    int allocPool(int n)
    {
        if (poolCount + n > pool.length)
        {
            size_t cap = pool.length * 2;
            while (cap < poolCount + n)
                cap *= 2;
            pool.length = cap;
        }
        immutable start = poolCount;
        poolCount += n;
        return start;
    }

    /// The tuple type whose components are `components` (copied into the pool).
    TypeId newTuple(const(TypeId)[] components)
    {
        immutable start = allocPool(cast(int) components.length);
        pool[start .. start + components.length] = components[];
        return newTupleAt(start, cast(int) components.length);
    }

    /// A tuple type over already-filled pool slots `pool[start .. start + n]`.
    TypeId newTupleAt(int start, int n)
    {
        immutable t = alloc(NodeKind.tuple);
        nodes[t].a = start;
        nodes[t].b = n;
        return t;
    }

    /// The representative of `t`, following (and compressing) variable links.
    TypeId find(TypeId t)
    {
        TypeId r = t;
        while (nodes[r].kind == NodeKind.variable && nodes[r].a >= 0)
            r = nodes[r].a;
        while (t != r)
        {
            immutable next = nodes[t].a;
            nodes[t].a = r;
            t = next;
        }
        return r;
    }

    /// True if `t` (a representative) is an unbound variable.
    bool isUnboundVar(TypeId t) const
    {
        return nodes[t].kind == NodeKind.variable && nodes[t].a < 0;
    }
}
