/// Pre-analysed program representation, procedures and environment frames.
module scheme.node;

import core.memory : GC;
import scheme.value;

/// The kind of a compiled `Node`.
enum Kind : ubyte
{
    constant, variable, set, define, if_, lambda, begin, app,
    let, namedLet, letStar, letrec, cond, and, or,
}

/// One `cond` clause.
struct Clause
{
    Node test;      /// null for `else`
    Node body;      /// null for `(test)` clauses
    bool isElse;
}

/// A compiled expression. One class with a kind tag; each kind uses the
/// subset of fields documented here.
final class Node
{
    Kind kind;
    int sym;          /// variable / set! / define target
    Value val;        /// constant value
    Node a, b, c;     /// if: test/then/else; set!/define: a = expr; app: a = operator
    Node[] kids;      /// begin/and/or forms; app operands
    Proc proc;        /// lambda / named-let procedure descriptor
    int[] names;      /// let family binding names (named let: [loop name])
    Node[] inits;     /// let family init expressions
    Node body;        /// let family body
    Clause[] clauses; /// cond

    this(Kind k) { kind = k; }
}

/// A procedure descriptor shared by every closure made from one `lambda`.
final class Proc
{
    int[] ids;        /// parameter ids, followed by the rest parameter if any
    int nfixed;       /// number of required parameters
    bool rest;        /// has a rest parameter
    Node body;
}

/// A closure: descriptor plus captured environment.
final class Closure
{
    Proc proc;
    Frame* env;

    this(Proc p, Frame* e) { proc = p; env = e; }
}

/// Wrap a closure as a `Value`.
Value closureValue(Closure c)
{
    Value r;
    r.tag = Tag.closure;
    r.p = cast(void*) c;
    return r;
}

/// The closure held by a `Value` with tag `closure`.
Closure asClosure(Value v) { return cast(Closure) v.p; }

/// An environment frame: parallel arrays of symbol ids and values. The value
/// array is allocated together with the frame header (see `create`).
struct Frame
{
    Frame* parent;
    int[] ids;
    Value[] vals;
    bool sharedIds; /// `ids` belongs to a descriptor and must be copied before growing

    /// Allocate a frame with `n` value slots (left for the caller to fill)
    /// in one block.
    static Frame* create(Frame* parent, int[] ids, size_t n, bool sharedIds)
    {
        void* mem = GC.malloc(Frame.sizeof + n * Value.sizeof);
        auto f = cast(Frame*) mem;
        f.parent = parent;
        f.ids = ids;
        f.vals = (cast(Value*)(mem + Frame.sizeof))[0 .. n];
        f.sharedIds = sharedIds;
        return f;
    }

    /// A frame holding exactly the given values.
    static Frame* create(Frame* parent, int[] ids, const(Value)[] vals, bool sharedIds)
    {
        auto f = create(parent, ids, vals.length, sharedIds);
        f.vals[] = vals[];
        return f;
    }

    /// Bind `id` in this frame, replacing an existing binding of the same id.
    void define(int id, Value v)
    {
        foreach (k, x; ids)
            if (x == id)
            {
                vals[k] = v;
                return;
            }
        if (sharedIds)
        {
            ids = ids.dup;
            sharedIds = false;
        }
        ids ~= id;
        vals ~= v;
    }
}
