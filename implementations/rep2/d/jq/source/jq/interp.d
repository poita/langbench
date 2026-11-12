/**
 * Tree-walking evaluator.
 *
 * Evaluation is push-based: $(D eval) calls a sink delegate once per output,
 * in order, so generators nest as plain loops, evaluation is lazy, and an
 * error (a $(D JqError) exception) aborts everything downstream of where it
 * was raised while outputs already delivered stay delivered.
 */
module jq.interp;

import std.array : appender;
import std.algorithm.sorting : sort;
import std.algorithm.mutation : SwapStrategy;

import jq.ast;
import jq.errors : JqError;
import jq.ops;
import jq.parser : parseFilter;
import jq.value;

/// Receives each output of a filter.
alias Sink = void delegate(Value);

/// A compiled filter program.
final class Filter
{
    private Node root;

    private this(Node root)
    {
        this.root = root;
    }

    /// Compiles `source`; throws $(D FilterSyntaxError) on malformed programs.
    static Filter compile(string source)
    {
        return new Filter(parseFilter(source));
    }

    /**
     * Runs the filter on `input`, calling `sink` for every output in order.
     * Throws $(D JqError) if evaluation fails; outputs produced before the
     * failure have already been passed to `sink`.
     */
    void run(Value input, scope Sink sink)
    {
        eval(root, input, null, sink);
    }

    /// Collects all outputs. Throws $(D JqError) if evaluation fails (outputs so far are lost).
    Value[] collect(Value input)
    {
        auto r = appender!(Value[]);
        run(input, (Value v) { r.put(v); });
        return r.data;
    }
}

/// Persistent (immutable linked-list) variable environment.
private final class Env
{
    string name;
    Value value;
    Env parent;

    this(string name, Value value, Env parent)
    {
        this.name = name;
        this.value = value;
        this.parent = parent;
    }
}

/// Carries an error out of a `try` body when it was raised downstream of the body.
private final class PassThrough : Exception
{
    Throwable inner;
    Object owner;

    this(Throwable inner, Object owner)
    {
        super("passthrough");
        this.inner = inner;
        this.owner = owner;
    }
}

private Value lookup(Env env, string name)
{
    for (; env !is null; env = env.parent)
        if (env.name == name)
            return env.value;
    throw new JqError("$" ~ name ~ " is not defined");
}

private void iterate(Value t, scope Sink emit)
{
    if (t.kind == Kind.array)
    {
        foreach (x; t.arr)
            emit(x);
    }
    else if (t.kind == Kind.object)
    {
        auto o = t.obj;
        foreach (x; o.values)
            emit(x);
    }
    else
        throw new JqError("cannot iterate over " ~ t.typeName);
}

private bool isIterable(Value t) @safe pure nothrow @nogc
{
    return t.kind == Kind.array || t.kind == Kind.object;
}

private void eval(Node n, Value input, Env env, scope Sink emit)
{
    final switch (n.kind)
    {
    case NodeKind.identity:
        emit(input);
        return;
    case NodeKind.literal:
        emit(n.lit);
        return;
    case NodeKind.variable:
        emit(lookup(env, n.name));
        return;
    case NodeKind.pipe:
        eval(n.a, input, env, (Value v) { eval(n.b, v, env, emit); });
        return;
    case NodeKind.comma:
        eval(n.a, input, env, emit);
        eval(n.b, input, env, emit);
        return;
    case NodeKind.binary:
        immutable op = n.op;
        eval(n.b, input, env, (Value rv) {
            eval(n.a, input, env, (Value lv) { emit(binaryOp(op, lv, rv)); });
        });
        return;
    case NodeKind.and:
        eval(n.a, input, env, (Value a) {
            if (!a.truthy)
                emit(Value.fromBool(false));
            else
                eval(n.b, input, env, (Value b) { emit(Value.fromBool(b.truthy)); });
        });
        return;
    case NodeKind.or:
        eval(n.a, input, env, (Value a) {
            if (a.truthy)
                emit(Value.fromBool(true));
            else
                eval(n.b, input, env, (Value b) { emit(Value.fromBool(b.truthy)); });
        });
        return;
    case NodeKind.neg:
        eval(n.a, input, env, (Value v) { emit(opNeg(v)); });
        return;
    case NodeKind.index:
        immutable opt = n.optional;
        eval(n.b, input, env, (Value k) {
            eval(n.a, input, env, (Value t) {
                if (opt)
                {
                    Value r;
                    if (tryIndex(t, k, r))
                        emit(r);
                }
                else
                    emit(index(t, k));
            });
        });
        return;
    case NodeKind.slice:
        evalSlice(n, input, env, emit);
        return;
    case NodeKind.iterate:
        immutable opt = n.optional;
        eval(n.a, input, env, (Value t) {
            if (opt && !isIterable(t))
                return;
            iterate(t, emit);
        });
        return;
    case NodeKind.try_:
        evalTry(n.a, input, env, emit);
        return;
    case NodeKind.array:
        auto items = appender!(Value[]);
        if (n.a !is null)
            eval(n.a, input, env, (Value v) { items.put(v); });
        emit(Value.fromArray(items.data));
        return;
    case NodeKind.object:
        auto ks = new string[n.keys.length];
        auto vs = new Value[n.keys.length];
        evalObject(n, 0, input, env, ks, vs, emit);
        return;
    case NodeKind.if_:
        eval(n.a, input, env, (Value c) {
            if (c.truthy)
                eval(n.b, input, env, emit);
            else if (n.c !is null)
                eval(n.c, input, env, emit);
            else
                emit(input);
        });
        return;
    case NodeKind.as:
        eval(n.a, input, env, (Value v) { eval(n.b, input, new Env(n.name, v, env), emit); });
        return;
    case NodeKind.reduce:
        eval(n.b, input, env, (Value init) {
            Value acc = init;
            eval(n.a, input, env, (Value v) {
                Value last;
                eval(n.c, acc, new Env(n.name, v, env), (Value o) { last = o; });
                acc = last; // null when UPDATE produced nothing
            });
            emit(acc);
        });
        return;
    case NodeKind.call:
        evalCall(n, input, env, emit);
        return;
    }
}

private void evalSlice(Node n, Value input, Env env, scope Sink emit)
{
    immutable opt = n.optional;
    void withBound(Node bound, scope void delegate(bool, Value) body_)
    {
        if (bound is null)
            body_(false, Value.nil);
        else
            eval(bound, input, env, (Value v) { body_(true, v); });
    }

    withBound(n.b, (bool hasFrom, Value from) {
        withBound(n.c, (bool hasTo, Value to) {
            eval(n.a, input, env, (Value t) {
                if (opt)
                {
                    Value r;
                    if (trySlice(t, hasFrom, from, hasTo, to, r))
                        emit(r);
                }
                else
                    emit(slice(t, hasFrom, from, hasTo, to));
            });
        });
    });
}

private void evalTry(Node body_, Value input, Env env, scope Sink emit)
{
    // Errors raised by `emit` (downstream of the body) must not be swallowed:
    // they are wrapped on the way out of the callback and unwrapped here.
    auto token = new Object;
    try
    {
        eval(body_, input, env, (Value v) {
            try
                emit(v);
            catch (JqError e)
                throw new PassThrough(e, token);
        });
    }
    catch (JqError)
    {
        // swallowed: the term stops at its first error
    }
    catch (PassThrough p)
    {
        if (p.owner is token)
            throw p.inner;
        throw p;
    }
}

private void evalObject(Node n, size_t i, Value input, Env env, string[] ks, Value[] vs, scope Sink emit)
{
    if (i == n.keys.length)
    {
        auto o = new JObject(ks.length);
        foreach (j; 0 .. ks.length)
            o.set(ks[j], vs[j]);
        emit(Value.fromObject(o));
        return;
    }
    eval(n.keys[i], input, env, (Value k) {
        if (k.kind != Kind.string)
            throw new JqError("object keys must be strings, not " ~ k.typeName);
        ks[i] = k.str;
        eval(n.values[i], input, env, (Value v) {
            vs[i] = v;
            evalObject(n, i + 1, input, env, ks, vs, emit);
        });
    });
}

private struct Keyed
{
    Value key;
    Value item;
}

/// Evaluates `[f]` for each element and returns the elements stably sorted by that key.
private Keyed[] sortedByKey(Node f, Value input, Env env)
{
    if (input.kind != Kind.array)
        throw new JqError(input.typeName ~ " cannot be sorted, as it is not an array");
    auto items = input.arr;
    auto keyed = new Keyed[items.length];
    foreach (i, x; items)
    {
        auto ks = appender!(Value[]);
        eval(f, x, env, (Value k) { ks.put(k); });
        keyed[i] = Keyed(Value.fromArray(ks.data), x);
    }
    keyed.sort!((a, b) => compare(a.key, b.key) < 0, SwapStrategy.stable);
    return keyed;
}

private void evalCall(Node n, Value input, Env env, scope Sink emit)
{
    final switch (n.fn)
    {
    case Builtin.empty:
        return;
    case Builtin.error0:
        throw new JqError(input, "error");
    case Builtin.error1:
        eval(n.args[0], input, env, (Value v) { throw new JqError(v, "error"); });
        return;
    case Builtin.not:
        emit(Value.fromBool(!input.truthy));
        return;
    case Builtin.length:
        emit(builtinLength(input));
        return;
    case Builtin.keys:
        emit(builtinKeys(input));
        return;
    case Builtin.has:
        eval(n.args[0], input, env, (Value k) { emit(builtinHas(input, k)); });
        return;
    case Builtin.type:
        emit(Value.fromString(input.typeName));
        return;
    case Builtin.add:
        emit(builtinAdd(input));
        return;
    case Builtin.select:
        eval(n.args[0], input, env, (Value c) {
            if (c.truthy)
                emit(input);
        });
        return;
    case Builtin.map:
        auto items = appender!(Value[]);
        iterate(input, (Value x) { eval(n.args[0], x, env, (Value y) { items.put(y); }); });
        emit(Value.fromArray(items.data));
        return;
    case Builtin.sort:
        emit(builtinSort(input));
        return;
    case Builtin.sortBy:
        auto keyed = sortedByKey(n.args[0], input, env);
        auto r = new Value[keyed.length];
        foreach (i, k; keyed)
            r[i] = k.item;
        emit(Value.fromArray(r));
        return;
    case Builtin.groupBy:
        auto keyed = sortedByKey(n.args[0], input, env);
        auto groups = appender!(Value[]);
        size_t start = 0;
        foreach (i; 1 .. keyed.length + 1)
        {
            if (i == keyed.length || compare(keyed[i].key, keyed[start].key) != 0)
            {
                auto g = new Value[i - start];
                foreach (j; start .. i)
                    g[j - start] = keyed[j].item;
                groups.put(Value.fromArray(g));
                start = i;
            }
        }
        emit(Value.fromArray(groups.data));
        return;
    case Builtin.unique:
        emit(builtinUnique(input));
        return;
    case Builtin.reverse:
        emit(builtinReverse(input));
        return;
    case Builtin.min:
        emit(builtinMin(input));
        return;
    case Builtin.max:
        emit(builtinMax(input));
        return;
    case Builtin.tostring:
        emit(builtinToString(input));
        return;
    case Builtin.tonumber:
        emit(builtinToNumber(input));
        return;
    }
}

/// Parses `filter` and `json` and returns all outputs. Throws on syntax or runtime errors.
Value[] query(string filter, string json)
{
    import jq.json : parseJson;

    return Filter.compile(filter).collect(parseJson(json));
}

version (unittest)
{
    import jq.json : toJson, parseJson;

    private string[] run(string filter, string json)
    {
        string[] r;
        Filter.compile(filter).run(parseJson(json), (Value v) { r ~= toJson(v); });
        return r;
    }

    private string[] runUntilError(string filter, string json, out bool errored)
    {
        string[] r;
        errored = false;
        try
            Filter.compile(filter).run(parseJson(json), (Value v) { r ~= toJson(v); });
        catch (JqError)
            errored = true;
        return r;
    }
}

unittest
{
    assert(run(".a.b", `{"a":{"b":[1,2]}}`) == [`[1,2]`]);
    assert(run(".[] | select(. > 1)", `[1,2,3]`) == [`2`, `3`]);
    assert(run("[(1,2) + (10,20)]", `null`) == [`[11,12,21,22]`]);
    assert(run("{a:(1,2), b:(3,4)}", `null`) == [`{"a":1,"b":3}`, `{"a":1,"b":4}`, `{"a":2,"b":3}`, `{"a":2,"b":4}`]);
    assert(run("([1,2],[3,4])[(0,1)]", `null`) == [`1`, `3`, `2`, `4`]);
    assert(run("{a:1,b:2,a:3}", `null`) == [`{"a":3,"b":2}`]);
    assert(run("1 as $x | {a, $x}", `{"a":5}`) == [`{"a":5,"x":1}`]);
    assert(run(`1 as $x | 2 as $y | [$x,$y,$x+$y]`, `null`) == [`[1,2,3]`]);
    assert(run(`reduce .[] as $x (0; . + $x)`, `[1,2,3]`) == [`6`]);
    assert(run(`reduce .[] as $x (0; empty)`, `[1,2,3]`) == [`null`]);
    assert(run(`if . then "t" elif . == null then "n" else "f" end`, `null`) == [`"n"`]);
    assert(run(`if false then 1 end`, `7`) == [`7`]);
    assert(run(`false and error`, `null`) == [`false`]);
    assert(run(`[.[] | tonumber?]`, `["1","x","2"]`) == [`[1,2]`]);
}

unittest
{
    bool err;
    assert(runUntilError(`(.[] | .a.b?)`, `[{"a":{"b":1}},{"a":5},3]`, err) == [`1`] && err);
    assert(run(`[.[] | .a?]`, `[{"a":{"b":1}},{"a":5},3]`) == [`[{"b":1},5]`]);
    assert(run(`[(1,2,error,3)?]`, `null`) == [`[1,2]`]);
    assert(run(`[([1],2,[3])[0]?]`, `null`) == [`[1,3]`]);
    assert(run(`[(1,[2],3)[]?]`, `null`) == [`[2]`]);
    assert(run(`(.a.b)?`, `5`) == []);
    assert(run(`.a?`, `5`) == []);
    runUntilError(`.a.b?`, `5`, err);
    assert(err);
    runUntilError(`(1,2)? | error`, `null`, err);
    assert(err);
    assert(runUntilError(`1, error, 2`, `null`, err) == [`1`] && err);
    assert(runUntilError(`((1,2)? | error)?`, `null`, err) == [] && !err);
}

unittest
{
    assert(run(`sort_by(.a, .b)`, `[{"a":2,"b":1},{"a":1,"b":2},{"a":1,"b":1}]`) ==
            [`[{"a":1,"b":1},{"a":1,"b":2},{"a":2,"b":1}]`]);
    assert(run(`group_by(.k) | map([.[0].k, length])`, `[{"k":"b"},{"k":"a"},{"k":"b"}]`) == [`[["a",1],["b",2]]`]);
    assert(run(`map(.v) | add`, `[{"v":1},{"v":5}]`) == [`6`]);
    assert(run(`.[1:] , .[:-1]`, `[1,2,3]`) == [`[2,3]`, `[1,2]`]);
    assert(run(`min, max`, `[3,1,2]`) == [`1`, `3`]);
    assert(run(`keys, length, has("a")`, `{"b":1,"a":2}`) == [`["a","b"]`, `2`, `true`]);
    assert(run(`-(.a + 1), 1 - -1`, `{"a":2}`) == [`-3`, `2`]);
}
