/// The tree-walking evaluator.
///
/// Evaluation is continuation-passing: `eval` pushes each output of a node to
/// a callback, in the order the specification defines, so streams are lazy and
/// results can be printed as they are produced. An error is a `JqError`
/// exception that unwinds the whole evaluation.
module jq.interp;

import std.array : Appender, appender;

import jq.ast;
import jq.error;
import jq.ops;
import jq.value;

/// Receives each output of a filter.
alias Yield = void delegate(Value);

/// A persistent (immutable, shared) variable environment.
struct Env
{
    int id;
    Value val;
    Env* parent;
}

private Value lookupVar(const(Env)* env, int id, string name)
{
    for (auto e = env; e !is null; e = e.parent)
        if (e.id == id)
            return cast() e.val;
    throw new JqError("$" ~ name ~ " is not defined");
}

// ---------------------------------------------------------------------------
// try/catch plumbing
// ---------------------------------------------------------------------------

/// Wraps an error raised *downstream* of a `try` body so that the `try` does
/// not swallow it.
private final class Downstream : Exception
{
    JqError inner;
    ulong owner;

    this(JqError e, ulong owner)
    {
        super("downstream");
        inner = e;
        this.owner = owner;
    }
}

private ulong tryCounter;

// ---------------------------------------------------------------------------
// Single-output fast path
// ---------------------------------------------------------------------------

/// Evaluates a node whose `single` flag is set: exactly one output or a raise.
Value evalSingle(Node n, Value inp, Env* env)
{
    final switch (n.op)
    {
    case Op.identity:
        return inp;
    case Op.literal:
        return n.lit;
    case Op.var:
        return lookupVar(env, n.varId, n.name);
    case Op.field:
        {
            auto t = n.a.op == Op.identity ? inp : evalSingle(n.a, inp, env);
            if (t.kind == Kind.Object)
            {
                auto p = t.obj.get(n.name);
                return p is null ? Value.makeNull() : *p;
            }
            return index(t, Value.makeString(n.name));
        }
    case Op.index:
        {
            auto k = evalSingle(n.b, inp, env);
            auto t = evalSingle(n.a, inp, env);
            return index(t, k);
        }
    case Op.pipe:
        return evalSingle(n.b, evalSingle(n.a, inp, env), env);
    case Op.binop:
        {
            auto b = evalSingle(n.b, inp, env);
            auto a = evalSingle(n.a, inp, env);
            return binop(n.bop, a, b);
        }
    case Op.and:
        {
            if (!evalSingle(n.a, inp, env).truthy)
                return Value.makeBool(false);
            return Value.makeBool(evalSingle(n.b, inp, env).truthy);
        }
    case Op.or:
        {
            if (evalSingle(n.a, inp, env).truthy)
                return Value.makeBool(true);
            return Value.makeBool(evalSingle(n.b, inp, env).truthy);
        }
    case Op.neg:
        return negate(evalSingle(n.a, inp, env));
    case Op.if_:
        {
            if (evalSingle(n.a, inp, env).truthy)
                return evalSingle(n.b, inp, env);
            return n.c is null ? inp : evalSingle(n.c, inp, env);
        }
    case Op.bind:
        {
            auto v = evalSingle(n.a, inp, env);
            auto e = new Env(n.varId, v, env);
            return evalSingle(n.b, inp, e);
        }
    case Op.array:
        {
            if (n.a is null)
                return Value.makeArray([]);
            auto out_ = appender!(Value[])();
            eval(n.a, inp, env, (Value v) { out_.put(v); });
            return Value.makeArray(out_.data);
        }
    case Op.object:
        return evalObjectSingle(n, inp, env);
    case Op.reduce:
        {
            return runReduce(n, evalSingle(n.b, inp, env), inp, env);
        }
    case Op.call:
        return callSingle(n, inp, env);
    case Op.slice:
    case Op.iterate:
    case Op.try_:
    case Op.comma:
        assert(false, "not a single-output node");
    }
}

private Value evalObjectSingle(Node n, Value inp, Env* env)
{
    auto b = ObjectBuilder(n.entries.length);
    foreach (ref e; n.entries)
    {
        string key = e.litKey;
        if (e.keyExpr !is null)
        {
            auto k = evalSingle(e.keyExpr, inp, env);
            if (k.kind != Kind.String)
                throw new JqError("Object keys must be strings");
            key = k.str;
        }
        b.set(key, evalSingle(e.val, inp, env));
    }
    return Value.makeObject(b.build());
}

private Value callSingle(Node n, Value inp, Env* env)
{
    final switch (n.bi)
    {
    case Builtin.error0:
        throw new JqError("error");
    case Builtin.not:
        return Value.makeBool(!inp.truthy);
    case Builtin.length:
        return length(inp);
    case Builtin.keys:
        return keys(inp);
    case Builtin.has:
        return has(inp, evalSingle(n.args[0], inp, env));
    case Builtin.type:
        return Value.makeString(inp.typeName);
    case Builtin.add:
        return add(inp);
    case Builtin.map:
        {
            auto f = n.args[0];
            auto xs = elementsOf(inp);
            if (f.single)
            {
                auto r = new Value[xs.length];
                foreach (i, x; xs)
                    r[i] = evalSingle(f, x, env);
                return Value.makeArray(r);
            }
            auto r = appender!(Value[])();
            foreach (x; xs)
                eval(f, x, env, (Value v) { r.put(v); });
            return Value.makeArray(r.data);
        }
    case Builtin.sort:
        return sortValues(inp);
    case Builtin.sort_by:
        {
            auto ks = keyedElements(n.args[0], inp, env);
            sortKeyed(ks);
            auto r = new Value[ks.length];
            foreach (i, ref k; ks)
                r[i] = k.val;
            return Value.makeArray(r);
        }
    case Builtin.group_by:
        {
            auto ks = keyedElements(n.args[0], inp, env);
            sortKeyed(ks);
            auto groups = appender!(Value[])();
            size_t i = 0;
            while (i < ks.length)
            {
                size_t j = i + 1;
                while (j < ks.length && compareArrays(ks[i].key, ks[j].key) == 0)
                    ++j;
                auto g = new Value[j - i];
                foreach (m; i .. j)
                    g[m - i] = ks[m].val;
                groups.put(Value.makeArray(g));
                i = j;
            }
            return Value.makeArray(groups.data);
        }
    case Builtin.unique:
        return unique(inp);
    case Builtin.reverse:
        return reverse(inp);
    case Builtin.min:
        return minMax(inp, false);
    case Builtin.max:
        return minMax(inp, true);
    case Builtin.tostring:
        return tostring(inp);
    case Builtin.tonumber:
        return tonumber(inp);
    case Builtin.empty:
    case Builtin.error1:
    case Builtin.select:
        assert(false, "not a single-output builtin");
    }
}

/// Pairs each element of the array `inp` with the array `[f]` of its keys.
private Keyed[] keyedElements(Node f, Value inp, Env* env)
{
    if (inp.kind != Kind.Array)
        throw new JqError(inp.typeName ~ " cannot be sorted, as it is not an array");
    auto ks = new Keyed[inp.arr.length];
    foreach (i, x; inp.arr)
    {
        if (f.single)
            ks[i] = Keyed([evalSingle(f, x, env)], x);
        else
        {
            auto a = appender!(Value[])();
            eval(f, x, env, (Value v) { a.put(v); });
            ks[i] = Keyed(a.data, x);
        }
    }
    return ks;
}

// ---------------------------------------------------------------------------
// General evaluation
// ---------------------------------------------------------------------------

/// Evaluates `n` on `inp`, passing every output to `y` in order.
void eval(Node n, Value inp, Env* env, scope Yield y)
{
    if (n.single)
    {
        y(evalSingle(n, inp, env));
        return;
    }
    final switch (n.op)
    {
    case Op.identity:
    case Op.literal:
    case Op.var:
    case Op.array:
        y(evalSingle(n, inp, env));
        break;
    case Op.neg:
        eval(n.a, inp, env, (Value v) { y(negate(v)); });
        break;
    case Op.object:
        evalObject(n, inp, env, y);
        break;
    case Op.reduce:
        eval(n.b, inp, env, (Value init) { y(runReduce(n, init, inp, env)); });
        break;
    case Op.field:
        evalTarget(n.a, inp, env, (Value t) {
            Value r;
            if (!tryIndex(t, Value.makeString(n.name), r))
            {
                if (n.opt)
                    return;
                throw indexError(t, Value.makeString(n.name));
            }
            y(r);
        });
        break;
    case Op.index:
        eval(n.b, inp, env, (Value k) {
            evalTarget(n.a, inp, env, (Value t) {
                Value r;
                if (!tryIndex(t, k, r))
                {
                    if (n.opt)
                        return;
                    throw indexError(t, k);
                }
                y(r);
            });
        });
        break;
    case Op.slice:
        evalOpt(n.b, inp, env, (Value from) {
            evalOpt(n.c, inp, env, (Value to) {
                evalTarget(n.a, inp, env, (Value t) {
                    Value r;
                    if (!trySlice(t, from, to, r))
                    {
                        if (n.opt)
                            return;
                        throw sliceError(t);
                    }
                    y(r);
                });
            });
        });
        break;
    case Op.iterate:
        evalTarget(n.a, inp, env, (Value t) {
            if (t.kind == Kind.Array)
            {
                foreach (x; t.arr)
                    y(x);
            }
            else if (t.kind == Kind.Object)
            {
                foreach (x; t.obj.vals)
                    y(x);
            }
            else if (!n.opt)
                throw iterateError(t);
        });
        break;
    case Op.try_:
        evalTry(n, inp, env, y);
        break;
    case Op.pipe:
        eval(n.a, inp, env, (Value v) { eval(n.b, v, env, y); });
        break;
    case Op.comma:
        eval(n.a, inp, env, y);
        eval(n.b, inp, env, y);
        break;
    case Op.binop:
        eval(n.b, inp, env, (Value bv) {
            eval(n.a, inp, env, (Value av) { y(binop(n.bop, av, bv)); });
        });
        break;
    case Op.and:
        eval(n.a, inp, env, (Value av) {
            if (!av.truthy)
                y(Value.makeBool(false));
            else
                eval(n.b, inp, env, (Value bv) { y(Value.makeBool(bv.truthy)); });
        });
        break;
    case Op.or:
        eval(n.a, inp, env, (Value av) {
            if (av.truthy)
                y(Value.makeBool(true));
            else
                eval(n.b, inp, env, (Value bv) { y(Value.makeBool(bv.truthy)); });
        });
        break;
    case Op.if_:
        eval(n.a, inp, env, (Value c) {
            if (c.truthy)
                eval(n.b, inp, env, y);
            else if (n.c !is null)
                eval(n.c, inp, env, y);
            else
                y(inp);
        });
        break;
    case Op.bind:
        eval(n.a, inp, env, (Value v) {
            auto e = new Env(n.varId, v, env);
            eval(n.b, inp, e, y);
        });
        break;
    case Op.call:
        evalCall(n, inp, env, y);
        break;
    }
}

private void evalTarget(Node t, Value inp, Env* env, scope Yield y)
{
    if (t.op == Op.identity)
        y(inp);
    else
        eval(t, inp, env, y);
}

/// Like `eval`, but a null node yields a single null ("omitted").
private void evalOpt(Node n, Value inp, Env* env, scope Yield y)
{
    if (n is null)
        y(Value.makeNull());
    else
        eval(n, inp, env, y);
}

private void evalCall(Node n, Value inp, Env* env, scope Yield y)
{
    switch (n.bi)
    {
    case Builtin.empty:
        break;
    case Builtin.select:
        {
            auto f = n.args[0];
            if (f.single)
            {
                if (evalSingle(f, inp, env).truthy)
                    y(inp);
            }
            else
                eval(f, inp, env, (Value c) {
                    if (c.truthy)
                        y(inp);
                });
            break;
        }
    case Builtin.error1:
        eval(n.args[0], inp, env, (Value m) { throw new JqError("error: " ~ describe(m)); });
        break;
    case Builtin.has:
        eval(n.args[0], inp, env, (Value k) { y(has(inp, k)); });
        break;
    default:
        assert(false, "unreachable builtin");
    }
}

private string describe(Value v)
{
    import jq.json : toJson;

    return toJson(v);
}

private void evalTry(Node n, Value inp, Env* env, scope Yield y)
{
    immutable id = ++tryCounter;
    try
    {
        eval(n.a, inp, env, (Value v) {
            try
                y(v);
            catch (JqError e)
                throw new Downstream(e, id);
        });
    }
    catch (JqError e)
    {
        // swallowed: the term stops at its first error
    }
    catch (Downstream d)
    {
        if (d.owner == id)
            throw d.inner;
        throw d;
    }
}

/// `reduce SRC as $x (init; UPDATE)` for one value of `init`.
private Value runReduce(Node n, Value init, Value inp, Env* env)
{
    auto acc = init;
    eval(n.a, inp, env, (Value v) {
        auto e = new Env(n.varId, v, env);
        Value last;
        bool got = false;
        eval(n.c, acc, e, (Value r) { last = r; got = true; });
        acc = got ? last : Value.makeNull();
    });
    return acc;
}

/// Object construction with generator entries: the first entry is the
/// outermost loop, and within an entry the key is outer to the value.
private void evalObject(Node n, Value inp, Env* env, scope Yield y)
{
    auto entries = n.entries;
    auto ks = new string[entries.length];
    auto vs = new Value[entries.length];

    void emit()
    {
        auto b = ObjectBuilder(ks.length);
        foreach (i; 0 .. ks.length)
            b.set(ks[i], vs[i]);
        y(Value.makeObject(b.build()));
    }

    void rec(size_t i)
    {
        if (i == entries.length)
        {
            emit();
            return;
        }
        void withKey(string key)
        {
            eval(entries[i].val, inp, env, (Value v) {
                ks[i] = key;
                vs[i] = v;
                rec(i + 1);
            });
        }

        if (entries[i].keyExpr is null)
            withKey(entries[i].litKey);
        else
            eval(entries[i].keyExpr, inp, env, (Value k) {
                if (k.kind != Kind.String)
                    throw new JqError("Object keys must be strings");
                withKey(k.str);
            });
    }

    rec(0);
}
