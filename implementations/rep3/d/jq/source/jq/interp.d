/// The tree-walking, push-style evaluator.
///
/// `eval(node, input, env, sink)` calls `sink(value)` once per output, in
/// stream order; nested generators are nested callbacks. Callbacks are
/// `scope` delegates so they live on the stack. Runtime errors are
/// `JqError` exceptions; `try` tells its own errors from downstream ones by
/// wrapping the latter in a `Downstream` exception tagged with the owning try.
module jq.interp;

import jq.arith;
import jq.ast;
import jq.builtins;
import jq.compare;
import jq.errors;
import jq.value;

/// Receives each output of a filter.
alias Sink = void delegate(Value);

/// A persistent variable environment node (lives on the evaluator's stack).
struct Env
{
    Env* parent;
    int id;
    Value val;
}

/// Carries a downstream error across the `try` that must not catch it.
private final class Downstream : Exception
{
    JqError inner;
    void* owner;

    this(JqError e, void* o) pure nothrow @safe
    {
        super("downstream error");
        inner = e;
        owner = o;
    }
}

/// Run `prog` on `input`, calling `sink` for every output. Throws `JqError`
/// if evaluation fails (outputs before the error have already been sent).
void run(Program prog, Value input, scope Sink sink)
{
    eval(prog.root, input, null, sink);
}

private Value lookupVar(Env* env, Node n)
{
    for (auto e = env; e !is null; e = e.parent)
        if (e.id == n.id)
            return e.val;
    throw new JqError("$" ~ n.str ~ " is not defined");
}

/// Growable array builder for `[f]` and `map`.
private struct ArrBuilder
{
    Value[] buf;
    size_t n;

    void put(Value v) nothrow
    {
        if (n == buf.length)
        {
            auto nb = new Value[n < 4 ? 4 : n * 2];
            nb[0 .. n] = buf[0 .. n];
            buf = nb;
        }
        buf[n++] = v;
    }

    Value result() nothrow @trusted
    {
        return mkArr(buf[0 .. n]);
    }
}

private Value collect(Node f, Value input, Env* env)
{
    ArrBuilder ab;
    if (f !is null)
        eval(f, input, env, (Value v) { ab.put(v); });
    return ab.result();
}

/// Evaluate a node that is guaranteed to produce exactly one output.
private Value evalOne(Node n, Value input, Env* env)
{
    final switch (n.kind)
    {
    case K.identity:
        return input;
    case K.literal:
        return n.lit;
    case K.variable:
        return lookupVar(env, n);
    case K.field:
        {
            Value t = n.a is null ? input : evalOne(n.a, input, env);
            Value r;
            if (!fieldOf(t, n.str, r))
                throw new JqError("cannot index with string");
            return r;
        }
    case K.index:
        {
            Value k = evalOne(n.b, input, env);
            Value t = n.a is null ? input : evalOne(n.a, input, env);
            Value r;
            if (!indexOf(t, k, r))
                throw new JqError("cannot index");
            return r;
        }
    case K.slice:
        {
            Value from = n.b is null ? mkNull() : evalOne(n.b, input, env);
            Value to = n.c is null ? mkNull() : evalOne(n.c, input, env);
            Value t = n.a is null ? input : evalOne(n.a, input, env);
            Value r;
            if (!sliceOf(t, from, to, r))
                throw new JqError("cannot slice");
            return r;
        }
    case K.neg:
        return negate(evalOne(n.a, input, env));
    case K.bin:
        {
            Value b = evalOne(n.b, input, env);
            Value a = evalOne(n.a, input, env);
            return binop(n.op, a, b);
        }
    case K.and:
        {
            if (!evalOne(n.a, input, env).truthy)
                return mkBool(false);
            return mkBool(evalOne(n.b, input, env).truthy);
        }
    case K.or:
        {
            if (evalOne(n.a, input, env).truthy)
                return mkBool(true);
            return mkBool(evalOne(n.b, input, env).truthy);
        }
    case K.pipe:
        return evalOne(n.b, evalOne(n.a, input, env), env);
    case K.array:
        return collect(n.a, input, env);
    case K.object:
        {
            auto ents = n.entries;
            if (n.litDistinct)
            {
                auto d = new Entry[ents.length];
                foreach (i, ref e; ents)
                    d[i] = Entry(e.keyLit, evalOne(e.val, input, env));
                return mkObj(Obj.exact(d));
            }
            auto o = new Obj(ents.length);
            foreach (ref e; ents)
            {
                string key = e.keyLit;
                if (e.keyExpr !is null)
                {
                    auto kv = evalOne(e.keyExpr, input, env);
                    if (!kv.isString)
                        throw new JqError("object keys must be strings");
                    key = kv.str;
                }
                o.set(key, evalOne(e.val, input, env));
            }
            return mkObj(o);
        }
    case K.call:
        return callSimple(n, input, env);
    case K.iterate, K.tryOp, K.comma, K.ifOp, K.asOp, K.reduce:
        assert(0, "not a simple node");
    }
}

private Value callSimple(Node n, Value input, Env* env)
{
    final switch (n.builtin)
    {
    case B.not: return mkBool(!input.truthy);
    case B.length: return lengthOf(input);
    case B.keys: return keysOf(input);
    case B.type: return mkStr(typeName(input));
    case B.add: return addAll(input);
    case B.reverse: return reverseOf(input);
    case B.sort: return sortValues(input);
    case B.unique: return uniqueValues(input);
    case B.min: return minMax(input, false);
    case B.max: return minMax(input, true);
    case B.tostring: return toStringV(input);
    case B.tonumber: return toNumberV(input);
    case B.has: return hasKey(input, evalOne(n.args[0], input, env));
    case B.map:
        {
            ArrBuilder ab;
            auto f = n.args[0];
            if (input.isArray)
            {
                foreach (x; input.arr)
                    eval(f, x, env, (Value v) { ab.put(v); });
            }
            else if (input.isObject)
            {
                foreach (ref e; input.obj.entries)
                    eval(f, e.val, env, (Value v) { ab.put(v); });
            }
            else
                throw new JqError("cannot iterate over it");
            return ab.result();
        }
    case B.sortBy, B.groupBy:
        {
            if (!input.isArray)
                throw new JqError("cannot be sorted");
            auto a = input.arr;
            auto keys = new Value[a.length];
            auto f = n.args[0];
            foreach (i, x; a)
                keys[i] = collect(f, x, env);
            return n.builtin == B.sortBy ? sortByKeys(input, keys) : groupByKeys(input, keys);
        }
    case B.empty, B.error, B.select:
        assert(0, "not a simple call");
    }
}

/// `t.key` step shared by the generator paths.
private void fieldStep(Node n, Value t, scope Sink sink)
{
    Value r;
    if (fieldOf(t, n.str, r))
        sink(r);
    else if (!n.opt)
        throw new JqError("cannot index with string");
}

private void indexStep(Node n, Value t, Value k, scope Sink sink)
{
    Value r;
    if (indexOf(t, k, r))
        sink(r);
    else if (!n.opt)
        throw new JqError("cannot index");
}

private void iterStep(Node n, Value t, scope Sink sink)
{
    if (t.isArray)
    {
        foreach (x; t.arr)
            sink(x);
    }
    else if (t.isObject)
    {
        foreach (ref e; t.obj.entries)
            sink(e.val);
    }
    else if (!n.opt)
        throw new JqError("cannot iterate over it");
}

private void evalMaybe(Node x, Value input, Env* env, scope Sink sink)
{
    if (x is null)
        sink(mkNull());
    else
        eval(x, input, env, sink);
}

/// Evaluate `n` on `input`, sending every output to `sink`.
void eval(Node n, Value input, Env* env, scope Sink sink)
{
    if (n.simple)
    {
        sink(evalOne(n, input, env));
        return;
    }
    final switch (n.kind)
    {
    case K.identity, K.literal, K.variable:
        sink(evalOne(n, input, env));
        return;
    case K.comma:
        eval(n.a, input, env, sink);
        eval(n.b, input, env, sink);
        return;
    case K.pipe:
        if (n.a.simple)
            eval(n.b, evalOne(n.a, input, env), env, sink);
        else
            eval(n.a, input, env, (Value v) { eval(n.b, v, env, sink); });
        return;
    case K.field:
        if (n.a is null)
            fieldStep(n, input, sink);
        else
            eval(n.a, input, env, (Value t) { fieldStep(n, t, sink); });
        return;
    case K.index:
        eval(n.b, input, env, (Value k) {
            if (n.a is null)
                indexStep(n, input, k, sink);
            else
                eval(n.a, input, env, (Value t) { indexStep(n, t, k, sink); });
        });
        return;
    case K.slice:
        evalMaybe(n.b, input, env, (Value from) {
            evalMaybe(n.c, input, env, (Value to) {
                void step(Value t)
                {
                    Value r;
                    if (sliceOf(t, from, to, r))
                        sink(r);
                    else if (!n.opt)
                        throw new JqError("cannot slice");
                }

                if (n.a is null)
                    step(input);
                else
                    eval(n.a, input, env, (Value t) { step(t); });
            });
        });
        return;
    case K.iterate:
        if (n.a is null)
            iterStep(n, input, sink);
        else
            eval(n.a, input, env, (Value t) { iterStep(n, t, sink); });
        return;
    case K.tryOp:
        evalTry(n, input, env, sink);
        return;
    case K.neg:
        eval(n.a, input, env, (Value v) { sink(negate(v)); });
        return;
    case K.bin:
        eval(n.b, input, env, (Value bv) {
            if (n.a.simple)
                sink(binop(n.op, evalOne(n.a, input, env), bv));
            else
                eval(n.a, input, env, (Value av) { sink(binop(n.op, av, bv)); });
        });
        return;
    case K.and:
        eval(n.a, input, env, (Value a) {
            if (!a.truthy)
                sink(mkBool(false));
            else
                eval(n.b, input, env, (Value b) { sink(mkBool(b.truthy)); });
        });
        return;
    case K.or:
        eval(n.a, input, env, (Value a) {
            if (a.truthy)
                sink(mkBool(true));
            else
                eval(n.b, input, env, (Value b) { sink(mkBool(b.truthy)); });
        });
        return;
    case K.array:
        sink(collect(n.a, input, env));
        return;
    case K.object:
        {
            auto slots = new Entry[n.entries.length];
            objStep(n, 0, input, env, slots, sink);
            return;
        }
    case K.ifOp:
        eval(n.a, input, env, (Value c) {
            if (c.truthy)
                eval(n.b, input, env, sink);
            else if (n.c !is null)
                eval(n.c, input, env, sink);
            else
                sink(input);
        });
        return;
    case K.asOp:
        eval(n.a, input, env, (Value v) {
            Env e = Env(env, n.id, v);
            eval(n.b, input, &e, sink);
        });
        return;
    case K.reduce:
        eval(n.b, input, env, (Value init) {
            Value acc = init;
            Env e = Env(env, n.id, mkNull());
            immutable updSimple = n.c.simple;
            eval(n.a, input, env, (Value x) {
                e.val = x;
                if (updSimple)
                    acc = evalOne(n.c, acc, &e);
                else
                {
                    Value last = mkNull();
                    eval(n.c, acc, &e, (Value r) { last = r; });
                    acc = last;
                }
            });
            sink(acc);
        });
        return;
    case K.call:
        callGen(n, input, env, sink);
        return;
    }
}

private void callGen(Node n, Value input, Env* env, scope Sink sink)
{
    switch (n.builtin)
    {
    case B.empty:
        return;
    case B.error:
        if (n.args.length == 0)
            throw new JqError("error");
        eval(n.args[0], input, env, (Value v) { throw new JqError("error"); });
        return;
    case B.select:
        if (n.args[0].simple)
        {
            if (evalOne(n.args[0], input, env).truthy)
                sink(input);
        }
        else
            eval(n.args[0], input, env, (Value c) {
                if (c.truthy)
                    sink(input);
            });
        return;
    case B.has:
        eval(n.args[0], input, env, (Value k) { sink(hasKey(input, k)); });
        return;
    default:
        sink(callSimple(n, input, env));
    }
}

private void objStep(Node n, size_t i, Value input, Env* env, Entry[] slots, scope Sink sink)
{
    auto ents = n.entries;
    if (i == ents.length)
    {
        Obj o;
        if (n.litDistinct)
            o = Obj.exact(slots.dup);
        else
        {
            o = new Obj(slots.length);
            foreach (ref s; slots)
                o.set(s.key, s.val);
        }
        sink(mkObj(o));
        return;
    }
    auto e = &ents[i];
    if (e.keyExpr is null)
    {
        immutable key = e.keyLit;
        eval(e.val, input, env, (Value v) {
            slots[i] = Entry(key, v);
            objStep(n, i + 1, input, env, slots, sink);
        });
    }
    else
    {
        eval(e.keyExpr, input, env, (Value kv) {
            if (!kv.isString)
                throw new JqError("object keys must be strings");
            immutable key = kv.str;
            eval(e.val, input, env, (Value v) {
                slots[i] = Entry(key, v);
                objStep(n, i + 1, input, env, slots, sink);
            });
        });
    }
}

private void evalTry(Node n, Value input, Env* env, scope Sink sink)
{
    ubyte marker;
    void* me = &marker;
    try
    {
        eval(n.a, input, env, (Value v) {
            try
                sink(v);
            catch (JqError e)
                throw new Downstream(e, me);
        });
    }
    catch (Downstream d)
    {
        if (d.owner is me)
            throw d.inner;
        throw d;
    }
    catch (JqError)
    {
        // error raised inside the term: swallowed, the term stops
    }
}
