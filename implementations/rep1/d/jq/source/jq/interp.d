/**
 * Tree-walking, push-style evaluator.
 *
 * `eval(node, input, env, sink)` calls `sink` once per output, in stream order.
 * A sink returns `false` to abort evaluation (an error has been recorded in
 * `Interpreter.err`). Nodes that produce exactly one output (`Node.single`) are
 * additionally evaluated by `evalOne` without callbacks.
 */
module jq.interp;

import jq.ast;
import jq.ops;
import jq.value;

/// Persistent variable environment: one node per binding.
final class Env
{
    int id;
    Value val;
    Env parent;
    this(int id, Value val, Env parent) pure nothrow @safe @nogc
    {
        this.id = id;
        this.val = val;
        this.parent = parent;
    }
}

/// Callback receiving each output; returns `false` to abort.
alias Sink = bool delegate(Value) nothrow;

private Value lookup(Env e, int id) pure nothrow @safe @nogc
{
    for (; e !is null; e = e.parent)
        if (e.id == id)
            return e.val;
    return Value.makeNull;
}

/// Evaluates an AST. One instance per run; not thread-safe.
final class Interpreter
{
    /// The pending error when an evaluation call returned `false`.
    Value err;

    private bool fail(Value e) nothrow
    {
        err = e;
        return false;
    }

    private static Value fieldOf(Value t, JStr key) nothrow
    {
        if (t.type == Type.object)
            return t.obj.get(key.s);
        if (t.type == Type.null_)
            return Value.makeNull;
        return Value.makeError("cannot index " ~ typeName(t.type) ~ " with \"" ~ key.s ~ "\"");
    }

    private static Value iterError(Value t) nothrow
    {
        return Value.makeError("cannot iterate over " ~ typeName(t.type));
    }

    // ------------------------------------------------------------------
    // Single-output evaluation
    // ------------------------------------------------------------------

    /// Evaluate a node with `single == true`; errors are returned as error values.
    Value evalOne(Node n, Value inp, Env env) nothrow
    {
        final switch (n.kind)
        {
        case Kind.identity:
            return inp;
        case Kind.literal:
            return n.lit;
        case Kind.variable:
            return lookup(env, n.varId);
        case Kind.field:
            {
                auto t = n.a.kind == Kind.identity ? inp : evalOne(n.a, inp, env);
                if (t.isError)
                    return t;
                return fieldOf(t, n.key);
            }
        case Kind.index:
            {
                auto k = evalOne(n.b, inp, env);
                if (k.isError)
                    return k;
                auto t = n.a.kind == Kind.identity ? inp : evalOne(n.a, inp, env);
                if (t.isError)
                    return t;
                return indexValue(t, k);
            }
        case Kind.slice:
            {
                auto lo = n.b is null ? Value.makeNull : evalOne(n.b, inp, env);
                if (lo.isError)
                    return lo;
                auto hi = n.c is null ? Value.makeNull : evalOne(n.c, inp, env);
                if (hi.isError)
                    return hi;
                auto t = evalOne(n.a, inp, env);
                if (t.isError)
                    return t;
                return sliceValue(t, lo, hi);
            }
        case Kind.neg:
            {
                auto v = evalOne(n.a, inp, env);
                if (v.isError)
                    return v;
                return opNeg(v);
            }
        case Kind.binop:
            {
                auto rb = evalOne(n.b, inp, env);
                if (rb.isError)
                    return rb;
                auto ra = evalOne(n.a, inp, env);
                if (ra.isError)
                    return ra;
                return applyBinary(n.op, ra, rb);
            }
        case Kind.and:
            {
                auto a = evalOne(n.a, inp, env);
                if (a.isError)
                    return a;
                if (!a.truthy)
                    return Value.makeBool(false);
                auto b = evalOne(n.b, inp, env);
                if (b.isError)
                    return b;
                return Value.makeBool(b.truthy);
            }
        case Kind.or:
            {
                auto a = evalOne(n.a, inp, env);
                if (a.isError)
                    return a;
                if (a.truthy)
                    return Value.makeBool(true);
                auto b = evalOne(n.b, inp, env);
                if (b.isError)
                    return b;
                return Value.makeBool(b.truthy);
            }
        case Kind.pipe:
            {
                auto v = evalOne(n.a, inp, env);
                if (v.isError)
                    return v;
                return evalOne(n.b, v, env);
            }
        case Kind.asOp:
            {
                auto v = evalOne(n.a, inp, env);
                if (v.isError)
                    return v;
                return evalOne(n.b, inp, new Env(n.varId, v, env));
            }
        case Kind.ifOp:
            {
                auto c = evalOne(n.a, inp, env);
                if (c.isError)
                    return c;
                return evalOne(c.truthy ? n.b : n.c, inp, env);
            }
        case Kind.objCons:
            return evalObjectOne(n, inp, env);
        case Kind.arrayCons:
            {
                if (n.a is null)
                    return Value.makeArray(null);
                if (n.a.single)
                {
                    auto v = evalOne(n.a, inp, env);
                    if (v.isError)
                        return v;
                    auto r = new Value[1];
                    r[0] = v;
                    return Value.makeArray(r);
                }
                Value[] out_;
                if (!eval(n.a, inp, env, (Value v) { out_ ~= v; return true; }))
                    return err;
                return Value.makeArray(out_);
            }
        case Kind.not:
            return Value.makeBool(!inp.truthy);
        case Kind.length:
            return opLength(inp);
        case Kind.keys:
            return opKeys(inp);
        case Kind.type:
            return opType(inp);
        case Kind.add:
            return opAddAll(inp);
        case Kind.sort:
            return opSort(inp);
        case Kind.unique:
            return opUnique(inp);
        case Kind.reverse:
            return opReverse(inp);
        case Kind.min:
            return opMinMax(inp, false);
        case Kind.max:
            return opMinMax(inp, true);
        case Kind.toStringOp:
            return opToString(inp);
        case Kind.toNumberOp:
            return opToNumber(inp);
        case Kind.has:
            {
                auto k = evalOne(n.a, inp, env);
                if (k.isError)
                    return k;
                return opHas(inp, k);
            }
        case Kind.map:
            return evalMap(n, inp, env);
        case Kind.sortBy:
        case Kind.groupBy:
            return evalSortGroup(n, inp, env);
        case Kind.reduce:
            {
                auto acc = evalOne(n.b, inp, env);
                if (acc.isError)
                    return acc;
                const ok = eval(n.a, inp, env, (Value x) {
                    auto nenv = new Env(n.varId, x, env);
                    if (n.c.single)
                    {
                        auto u = evalOne(n.c, acc, nenv);
                        if (u.isError)
                            return fail(u);
                        acc = u;
                        return true;
                    }
                    Value last;
                    bool got = false;
                    if (!eval(n.c, acc, nenv, (Value u) { last = u; got = true; return true; }))
                        return false;
                    acc = got ? last : Value.makeNull;
                    return true;
                });
                if (!ok)
                    return err;
                return acc;
            }
        case Kind.iterate, Kind.tryOp, Kind.comma, Kind.empty, Kind.error, Kind.errorOf, Kind.select:
            assert(0, "not a single-output node");
        }
    }

    private Value evalObjectOne(Node n, Value inp, Env env) nothrow
    {
        const m = n.ks.length;
        if (m == 0)
            return Value.makeObject(new JObj());
        auto vals = new Value[m];
        if (n.distinctLiteralKeys)
        {
            foreach (i; 0 .. m)
            {
                auto v = evalOne(n.vs[i], inp, env);
                if (v.isError)
                    return v;
                vals[i] = v;
            }
            return Value.makeObject(new JObj(n.litKeys, vals));
        }
        auto keys = new JStr[m];
        foreach (i; 0 .. m)
        {
            auto k = evalOne(n.ks[i], inp, env);
            if (k.isError)
                return k;
            if (k.type != Type.string)
                return Value.makeError("object keys must be strings");
            keys[i] = k.str;
            auto v = evalOne(n.vs[i], inp, env);
            if (v.isError)
                return v;
            vals[i] = v;
        }
        return Value.makeObject(buildObject(keys, vals));
    }

    private static JObj buildObject(JStr[] keys, Value[] vals) nothrow
    {
        auto o = new JObj();
        o.keys.reserve(keys.length);
        o.vals.reserve(keys.length);
        foreach (i, k; keys)
            o.set(k, vals[i]);
        return o;
    }

    private Value evalMap(Node n, Value inp, Env env) nothrow
    {
        Value[] src;
        if (inp.type == Type.array)
            src = inp.arr.items;
        else if (inp.type == Type.object)
            src = inp.obj.vals;
        else
            return iterError(inp);
        if (n.a.single)
        {
            auto r = new Value[src.length];
            foreach (i, x; src)
            {
                auto v = evalOne(n.a, x, env);
                if (v.isError)
                    return v;
                r[i] = v;
            }
            return Value.makeArray(r);
        }
        Value[] r;
        foreach (x; src)
            if (!eval(n.a, x, env, (Value v) { r ~= v; return true; }))
                return err;
        return Value.makeArray(r);
    }

    private Value evalSortGroup(Node n, Value inp, Env env) nothrow
    {
        if (inp.type != Type.array)
            return Value.makeError(typeName(inp.type) ~ " cannot be sorted, as it is not an array");
        auto items = inp.arr.items;
        auto keys = new Value[items.length];
        foreach (i, x; items)
        {
            if (n.a.single)
            {
                auto k = evalOne(n.a, x, env);
                if (k.isError)
                    return k;
                keys[i] = k;
            }
            else
            {
                Value[] ks;
                if (!eval(n.a, x, env, (Value v) { ks ~= v; return true; }))
                    return err;
                keys[i] = Value.makeArray(ks);
            }
        }
        auto perm = sortedPermutation(keys);
        if (n.kind == Kind.sortBy)
        {
            auto r = new Value[items.length];
            foreach (i, p; perm)
                r[i] = items[p];
            return Value.makeArray(r);
        }
        Value[] groups;
        Value[] cur;
        size_t prev = 0;
        foreach (i, p; perm)
        {
            if (i > 0 && compare(keys[prev], keys[p]) != 0)
            {
                groups ~= Value.makeArray(cur);
                cur = null;
            }
            cur ~= items[p];
            prev = p;
        }
        if (perm.length > 0)
            groups ~= Value.makeArray(cur);
        return Value.makeArray(groups);
    }

    // ------------------------------------------------------------------
    // General (generator) evaluation
    // ------------------------------------------------------------------

    /// Evaluate `n` on `inp`, pushing each output to `sink`. Returns `false` if aborted.
    bool eval(Node n, Value inp, Env env, scope Sink sink) nothrow
    {
        if (n.single)
        {
            auto v = evalOne(n, inp, env);
            if (v.isError)
                return fail(v);
            return sink(v);
        }
        final switch (n.kind)
        {
        case Kind.field:
            return eval(n.a, inp, env, (Value t) {
                auto r = fieldOf(t, n.key);
                if (r.isError)
                    return n.opt ? true : fail(r);
                return sink(r);
            });
        case Kind.index:
            return eval(n.b, inp, env, (Value k) {
                return eval(n.a, inp, env, (Value t) {
                    auto r = indexValue(t, k);
                    if (r.isError)
                        return n.opt ? true : fail(r);
                    return sink(r);
                });
            });
        case Kind.slice:
            return evalBound(n.b, inp, env, (Value lo) {
                return evalBound(n.c, inp, env, (Value hi) {
                    return eval(n.a, inp, env, (Value t) {
                        auto r = sliceValue(t, lo, hi);
                        if (r.isError)
                            return n.opt ? true : fail(r);
                        return sink(r);
                    });
                });
            });
        case Kind.iterate:
            return eval(n.a, inp, env, (Value t) {
                if (t.type == Type.array)
                {
                    foreach (x; t.arr.items)
                        if (!sink(x))
                            return false;
                    return true;
                }
                if (t.type == Type.object)
                {
                    foreach (x; t.obj.vals)
                        if (!sink(x))
                            return false;
                    return true;
                }
                return n.opt ? true : fail(iterError(t));
            });
        case Kind.tryOp:
            {
                bool downstream = false;
                const ok = eval(n.a, inp, env, (Value v) {
                    if (!sink(v))
                    {
                        downstream = true;
                        return false;
                    }
                    return true;
                });
                return ok || !downstream;
            }
        case Kind.pipe:
            return eval(n.a, inp, env, (Value v) { return eval(n.b, v, env, sink); });
        case Kind.comma:
            if (!eval(n.a, inp, env, sink))
                return false;
            return eval(n.b, inp, env, sink);
        case Kind.binop:
            return eval(n.b, inp, env, (Value rb) {
                return eval(n.a, inp, env, (Value ra) {
                    auto r = applyBinary(n.op, ra, rb);
                    if (r.isError)
                        return fail(r);
                    return sink(r);
                });
            });
        case Kind.and:
            return eval(n.a, inp, env, (Value a) {
                if (!a.truthy)
                    return sink(Value.makeBool(false));
                return eval(n.b, inp, env, (Value b) { return sink(Value.makeBool(b.truthy)); });
            });
        case Kind.or:
            return eval(n.a, inp, env, (Value a) {
                if (a.truthy)
                    return sink(Value.makeBool(true));
                return eval(n.b, inp, env, (Value b) { return sink(Value.makeBool(b.truthy)); });
            });
        case Kind.neg:
            return eval(n.a, inp, env, (Value v) {
                auto r = opNeg(v);
                if (r.isError)
                    return fail(r);
                return sink(r);
            });
        case Kind.objCons:
            {
                auto keys = new JStr[n.ks.length];
                auto vals = new Value[n.ks.length];
                return objStep(n, 0, keys, vals, inp, env, sink);
            }
        case Kind.ifOp:
            return eval(n.a, inp, env, (Value c) { return eval(c.truthy ? n.b : n.c, inp, env, sink); });
        case Kind.asOp:
            return eval(n.a, inp, env, (Value v) {
                return eval(n.b, inp, new Env(n.varId, v, env), sink);
            });
        case Kind.reduce:
            return eval(n.b, inp, env, (Value init) {
                Value acc = init;
                const ok = eval(n.a, inp, env, (Value x) {
                    auto nenv = new Env(n.varId, x, env);
                    Value last;
                    bool got = false;
                    if (!eval(n.c, acc, nenv, (Value u) { last = u; got = true; return true; }))
                        return false;
                    acc = got ? last : Value.makeNull;
                    return true;
                });
                return ok && sink(acc);
            });
        case Kind.empty:
            return true;
        case Kind.error:
            return fail(Value.makeError("error"));
        case Kind.errorOf:
            return eval(n.a, inp, env, (Value v) { return fail(Value.makeError("error (custom)")); });
        case Kind.select:
            return eval(n.a, inp, env, (Value c) { return c.truthy ? sink(inp) : true; });
        case Kind.has:
            return eval(n.a, inp, env, (Value k) {
                auto r = opHas(inp, k);
                if (r.isError)
                    return fail(r);
                return sink(r);
            });
        case Kind.identity, Kind.literal, Kind.variable, Kind.arrayCons, Kind.not, Kind.length,
            Kind.keys, Kind.type, Kind.add, Kind.sort, Kind.unique, Kind.reverse, Kind.min,
            Kind.max, Kind.toStringOp, Kind.toNumberOp, Kind.map, Kind.sortBy, Kind.groupBy:
            assert(0, "single-output node reached the generator path");
        }
    }

    private bool evalBound(Node b, Value inp, Env env, scope Sink sink) nothrow
    {
        if (b is null)
            return sink(Value.makeNull);
        return eval(b, inp, env, sink);
    }

    private bool objStep(Node n, size_t i, JStr[] keys, Value[] vals, Value inp, Env env, scope Sink sink) nothrow
    {
        if (i == n.ks.length)
        {
            if (n.distinctLiteralKeys)
                return sink(Value.makeObject(new JObj(n.litKeys, vals.dup)));
            return sink(Value.makeObject(buildObject(keys, vals)));
        }
        return eval(n.ks[i], inp, env, (Value k) {
            if (k.type != Type.string)
                return fail(Value.makeError("object keys must be strings"));
            keys[i] = k.str;
            return eval(n.vs[i], inp, env, (Value v) {
                vals[i] = v;
                return objStep(n, i + 1, keys, vals, inp, env, sink);
            });
        });
    }
}
