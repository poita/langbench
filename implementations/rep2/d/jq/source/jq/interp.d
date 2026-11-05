/**
 * Tree-walking, push-style evaluator.
 *
 * `Interpreter.eval(node, input, env, sink)` calls `sink(value)` once per
 * output, in stream order. A sink (and `eval` itself) returns `false` to abort:
 * either because an error was raised (`hasError` is then set) or because the
 * consumer asked to stop. Sinks are `scope` delegates, so evaluating a node
 * allocates no closures on the heap.
 */
module jq.interp;

import std.array : Appender;
import std.math : floor, ceil, fabs;

import jq.ast;
import jq.json;
import jq.parser;
import jq.value;

/// A raised jq error.
struct JqError
{
    /// Human-readable description.
    string message;
    /// The value passed to `error(...)`, or the message as a string.
    Value value;
}

/// A node of the persistent variable environment; lives on the evaluator's stack.
struct Env
{
    Env* parent;
    Value val;
}

/// Receives each output of a filter; return `false` to stop evaluation.
alias Sink = bool delegate(Value);

/// A compiled filter.
final class Program
{
    private Node root;
    private Interpreter interp;

    /// Compile `filter`. Throws $(REF ParseException, jq,lexer).
    this(string filter)
    {
        root = parseFilter(filter);
        interp = new Interpreter;
    }

    /**
     * Run the filter on `input`, calling `emit` for each output in order.
     * Returns `true` if evaluation finished (or `emit` asked to stop) and
     * `false` if an error was raised, in which case `error` describes it.
     * Outputs produced before the error have already been passed to `emit`.
     */
    bool run(Value input, scope Sink emit, out JqError error)
    {
        interp.hasError = false;
        interp.eval(root, input, null, emit);
        if (interp.hasError)
        {
            error = JqError(interp.errorMessage, interp.errorValue);
            return false;
        }
        return true;
    }

    /// Collect all outputs into an array; throws `JqException` on error.
    Value[] runAll(Value input)
    {
        Appender!(Value[]) app;
        JqError err;
        if (!run(input, (Value v) { app.put(v); return true; }, err))
            throw new JqException(err);
        return app.data;
    }
}

/// Thrown by $(LREF Program.runAll) when the filter raises an error.
class JqException : Exception
{
    /// The error.
    JqError error;

    ///
    this(JqError e, string file = __FILE__, size_t line = __LINE__)
    {
        super(e.message, file, line);
        error = e;
    }
}

private Value lookupVar(Env* e, int depth) pure nothrow @nogc @safe
{
    while (depth-- > 0)
        e = e.parent;
    return e.val;
}

/// Arithmetic and comparison on two values. On failure returns false and sets `err`.
bool binaryOp(BinOp op, Value a, Value b, out Value r, out string err)
{
    final switch (op)
    {
    case BinOp.eq:
        r = Value.boolean(compare(a, b) == 0);
        return true;
    case BinOp.ne:
        r = Value.boolean(compare(a, b) != 0);
        return true;
    case BinOp.lt:
        r = Value.boolean(compare(a, b) < 0);
        return true;
    case BinOp.le:
        r = Value.boolean(compare(a, b) <= 0);
        return true;
    case BinOp.gt:
        r = Value.boolean(compare(a, b) > 0);
        return true;
    case BinOp.ge:
        r = Value.boolean(compare(a, b) >= 0);
        return true;
    case BinOp.add:
        return addValues(a, b, r, err);
    case BinOp.sub:
        if (a.kind == Kind.number && b.kind == Kind.number)
        {
            r = Value.number(a.num - b.num);
            return true;
        }
        if (a.kind == Kind.array && b.kind == Kind.array)
        {
            Appender!(Value[]) app;
            auto bi = b.items;
            foreach (x; a.items)
            {
                bool found = false;
                foreach (y; bi)
                    if (compare(x, y) == 0)
                    {
                        found = true;
                        break;
                    }
                if (!found)
                    app.put(x);
            }
            r = Value.array(app.data);
            return true;
        }
        err = typeErr(a, b, "cannot be subtracted");
        return false;
    case BinOp.mul:
        if (a.kind == Kind.number && b.kind == Kind.number)
        {
            r = Value.number(a.num * b.num);
            return true;
        }
        if ((a.kind == Kind.string_ && b.kind == Kind.number) || (a.kind == Kind.number && b.kind == Kind.string_))
        {
            immutable s = a.kind == Kind.string_ ? a : b;
            immutable d = a.kind == Kind.number ? a.num : b.num;
            if (d < 0)
            {
                r = Value.nullValue;
                return true;
            }
            immutable n = cast(size_t) d;
            auto text = s.str;
            auto buf = new char[](text.length * n);
            foreach (i; 0 .. n)
                buf[i * text.length .. (i + 1) * text.length] = text[];
            r = Value.string_(cast(string) buf);
            return true;
        }
        if (a.kind == Kind.object && b.kind == Kind.object)
        {
            r = deepMerge(a, b);
            return true;
        }
        err = typeErr(a, b, "cannot be multiplied");
        return false;
    case BinOp.div:
        if (a.kind == Kind.number && b.kind == Kind.number)
        {
            if (b.num == 0)
            {
                err = typeErr(a, b, "cannot be divided because the divisor is zero");
                return false;
            }
            r = Value.number(a.num / b.num);
            return true;
        }
        if (a.kind == Kind.string_ && b.kind == Kind.string_)
        {
            r = splitString(a.str, b.str);
            return true;
        }
        err = typeErr(a, b, "cannot be divided");
        return false;
    case BinOp.mod:
        if (a.kind == Kind.number && b.kind == Kind.number)
        {
            immutable long x = cast(long) a.num, y = cast(long) b.num;
            if (y == 0)
            {
                err = typeErr(a, b, "cannot be divided because the divisor is zero");
                return false;
            }
            r = Value.number(y == -1 ? 0.0 : cast(double)(x % y));
            return true;
        }
        err = typeErr(a, b, "cannot be divided");
        return false;
    }
}

private string typeErr(Value a, Value b, string what)
{
    return typeName(a.kind) ~ " (" ~ toJson(a) ~ ") and " ~ typeName(b.kind) ~ " (" ~ toJson(b) ~ ") " ~ what;
}

private bool addValues(Value a, Value b, out Value r, out string err)
{
    if (a.kind == Kind.null_)
    {
        r = b;
        return true;
    }
    if (b.kind == Kind.null_)
    {
        r = a;
        return true;
    }
    if (a.kind == b.kind)
    {
        switch (a.kind)
        {
        case Kind.number:
            r = Value.number(a.num + b.num);
            return true;
        case Kind.string_:
            r = Value.string_(a.str ~ b.str);
            return true;
        case Kind.array:
            r = Value.array(a.items ~ b.items);
            return true;
        case Kind.object:
            {
                auto bo = b.obj;
                if (bo.length == 0)
                {
                    r = a;
                    return true;
                }
                auto o = a.obj.copy(bo.length);
                foreach (ref e; bo.entries)
                    o.set(e.key, e.val);
                r = Value.object(o);
                return true;
            }
        default:
            break;
        }
    }
    err = typeErr(a, b, "cannot be added");
    return false;
}

private Value deepMerge(Value a, Value b)
{
    auto bo = b.obj;
    auto o = a.obj.copy(bo.length);
    foreach (ref e; bo.entries)
    {
        bool found;
        auto cur = o.get(e.key, found);
        if (found && cur.kind == Kind.object && e.val.kind == Kind.object)
            o.set(e.key, deepMerge(cur, e.val));
        else
            o.set(e.key, e.val);
    }
    return Value.object(o);
}

private Value splitString(string s, string sep)
{
    Appender!(Value[]) app;
    if (s.length == 0)
        return Value.array(null);
    if (sep.length == 0)
    {
        size_t i = 0;
        while (i < s.length)
        {
            size_t j = i + 1;
            while (j < s.length && (cast(ubyte) s[j] & 0xC0) == 0x80)
                ++j;
            app.put(Value.string_(s[i .. j]));
            i = j;
        }
        return Value.array(app.data);
    }
    size_t start = 0, i = 0;
    while (i + sep.length <= s.length)
    {
        if (s[i] == sep[0] && s[i .. i + sep.length] == sep)
        {
            app.put(Value.string_(s[start .. i]));
            i += sep.length;
            start = i;
        }
        else
            ++i;
    }
    app.put(Value.string_(s[start .. $]));
    return Value.array(app.data);
}

/// `t[k]` for a single target and key. Returns false if the operation is an error.
bool indexOp(Value t, Value k, out Value r)
{
    if (k.kind == Kind.string_)
    {
        if (t.kind == Kind.object)
        {
            bool found;
            r = t.obj.get(k.jstr, found);
            return true;
        }
        if (t.kind == Kind.null_)
        {
            r = Value.nullValue;
            return true;
        }
        return false;
    }
    if (k.kind == Kind.number)
    {
        if (t.kind == Kind.array)
        {
            auto items = t.items;
            double d = k.num;
            if (d < 0)
                d += items.length;
            // truncation toward zero for fractional indices
            if (d <= -1 || d >= items.length)
                r = Value.nullValue;
            else
                r = items[cast(size_t) d];
            return true;
        }
        if (t.kind == Kind.null_)
        {
            r = Value.nullValue;
            return true;
        }
    }
    return false;
}

private string indexErr(Value t, Value k)
{
    if (k.kind == Kind.string_)
        return "Cannot index " ~ typeName(t.kind) ~ " with \"" ~ k.str ~ "\"";
    return "Cannot index " ~ typeName(t.kind) ~ " with " ~ typeName(k.kind);
}

/// `t[from:to]`; `from`/`to` are numbers or null (= default). False if it is an error.
bool sliceOp(Value t, Value from, Value to, out Value r)
{
    if (t.kind == Kind.null_)
    {
        r = Value.nullValue;
        return true;
    }
    if ((t.kind != Kind.array && t.kind != Kind.string_)
        || (from.kind != Kind.number && from.kind != Kind.null_)
        || (to.kind != Kind.number && to.kind != Kind.null_))
        return false;
    immutable len = t.kind == Kind.array ? t.items.length : codePointCount(t.str);
    double ds = from.kind == Kind.null_ ? 0 : from.num;
    double de = to.kind == Kind.null_ ? cast(double) len : to.num;
    if (ds < 0)
        ds += len;
    if (de < 0)
        de += len;
    if (ds < 0)
        ds = 0;
    if (ds > len)
        ds = len;
    if (de > len)
        de = len;
    if (de < ds)
        de = ds;
    immutable size_t s = cast(size_t) floor(ds);
    size_t e = cast(size_t) ceil(de);
    if (e > len)
        e = len;
    if (t.kind == Kind.array)
        r = Value.array(t.items[s .. e].dup);
    else
    {
        auto text = t.str;
        immutable bs = byteOffsetOfCodePoint(text, s);
        immutable be = bs + byteOffsetOfCodePoint(text[bs .. $], e - s);
        r = Value.string_(text[bs .. be]);
    }
    return true;
}

private string sliceErr(Value t)
{
    return "Cannot index " ~ typeName(t.kind) ~ " with object";
}

private Value keysOf(Value v, out bool ok)
{
    ok = true;
    if (v.kind == Kind.object)
    {
        auto o = v.obj;
        auto order = o.sortedOrder;
        auto ents = o.entries;
        auto res = new Value[](order.length);
        foreach (i, p; order)
            res[i] = Value.string_(ents[p].key);
        return Value.array(res);
    }
    if (v.kind == Kind.array)
    {
        auto res = new Value[](v.items.length);
        foreach (i; 0 .. res.length)
            res[i] = Value.number(i);
        return Value.array(res);
    }
    ok = false;
    return Value.init;
}

private bool hasOp(Value t, Value k, out bool result)
{
    if (t.kind == Kind.object && k.kind == Kind.string_)
    {
        result = t.obj.has(k.jstr);
        return true;
    }
    if (t.kind == Kind.array && k.kind == Kind.number)
    {
        result = k.num > -1 && k.num < t.items.length;
        return true;
    }
    if (t.kind == Kind.null_)
    {
        result = false;
        return true;
    }
    return false;
}

private bool lengthOp(Value v, out Value r)
{
    switch (v.kind)
    {
    case Kind.null_:
        r = Value.number(0);
        return true;
    case Kind.number:
        r = Value.number(fabs(v.num));
        return true;
    case Kind.string_:
        r = Value.number(codePointCount(v.str));
        return true;
    case Kind.array:
        r = Value.number(v.items.length);
        return true;
    case Kind.object:
        r = Value.number(v.obj.length);
        return true;
    default:
        return false;
    }
}

/// Sum / concatenate elements with `+` in one linear pass. False (with `err`) on a type mismatch.
bool addAll(Value[] xs, out Value r, out string err)
{
    enum Mode
    {
        none,
        str,
        arr,
        obj
    }

    Mode mode = Mode.none;
    Value acc;
    double sum = 0;
    Appender!(char[]) sbuf;
    Appender!(Value[]) abuf;
    JObject ob;
    foreach (x; xs)
    {
        if (x.kind == Kind.null_)
            continue;
        if (acc.kind == Kind.null_)
        {
            acc = x;
            if (x.kind == Kind.number)
                sum = x.num;
            continue;
        }
        if (acc.kind != x.kind)
        {
            err = typeErr(acc, x, "cannot be added");
            return false;
        }
        switch (acc.kind)
        {
        case Kind.number:
            sum += x.num;
            break;
        case Kind.string_:
            if (mode != Mode.str)
            {
                sbuf.put(acc.str);
                mode = Mode.str;
            }
            sbuf.put(x.str);
            break;
        case Kind.array:
            if (mode != Mode.arr)
            {
                abuf.put(acc.items);
                mode = Mode.arr;
            }
            abuf.put(x.items);
            break;
        case Kind.object:
            if (mode != Mode.obj)
            {
                ob = acc.obj.copy(x.obj.length);
                mode = Mode.obj;
            }
            foreach (ref e; x.obj.entries)
                ob.set(e.key, e.val);
            break;
        default:
            err = typeErr(acc, x, "cannot be added");
            return false;
        }
    }
    final switch (acc.kind)
    {
    case Kind.number:
        r = Value.number(sum);
        break;
    case Kind.string_:
        r = mode == Mode.str ? Value.string_(cast(string) sbuf.data) : acc;
        break;
    case Kind.array:
        r = mode == Mode.arr ? Value.array(abuf.data) : acc;
        break;
    case Kind.object:
        r = mode == Mode.obj ? Value.object(ob) : acc;
        break;
    case Kind.null_:
    case Kind.false_:
    case Kind.true_:
        r = acc;
        break;
    }
    return true;
}

private Value[] valuesOf(Value v, out bool ok)
{
    ok = true;
    if (v.kind == Kind.array)
        return v.items;
    if (v.kind == Kind.object)
    {
        auto ents = v.obj.entries;
        auto res = new Value[](ents.length);
        foreach (i, ref e; ents)
            res[i] = e.val;
        return res;
    }
    ok = false;
    return null;
}

private bool tonumberOp(Value v, out Value r)
{
    if (v.kind == Kind.number)
    {
        r = v;
        return true;
    }
    if (v.kind == Kind.string_)
    {
        auto s = v.str;
        size_t pos = 0;
        double d;
        if (scanNumber(s, pos, d) && pos == s.length)
        {
            r = Value.number(d);
            return true;
        }
    }
    return false;
}

private bool reverseOp(Value v, out Value r)
{
    if (v.kind == Kind.null_)
    {
        r = Value.array(null);
        return true;
    }
    if (v.kind == Kind.object && v.obj.length == 0)
    {
        r = Value.array(null); // jq's `[.[length - 1 - range(0; length)]]` is empty here
        return true;
    }
    if (v.kind != Kind.array)
        return false;
    auto src = v.items;
    auto res = new Value[](src.length);
    foreach (i, x; src)
        res[src.length - 1 - i] = x;
    r = Value.array(res);
    return true;
}

private Value gather(Value[] items, const(uint)[] order)
{
    auto res = new Value[](order.length);
    foreach (i, p; order)
        res[i] = items[p];
    return Value.array(res);
}

private uint[] sortedByValue(Value[] items)
{
    return stableOrder(items.length, (a, b) => compare(items[a], items[b]));
}

/// Builtins that take no arguments and yield exactly one output (or an error).
bool callNullary(Builtin fn, Value in_, out Value r, out string err)
{
    final switch (fn)
    {
    case Builtin.not:
        r = Value.boolean(!in_.truthy);
        return true;
    case Builtin.length:
        if (lengthOp(in_, r))
            return true;
        err = typeName(in_.kind) ~ " (" ~ toJson(in_) ~ ") has no length";
        return false;
    case Builtin.keys:
        {
            bool ok;
            r = keysOf(in_, ok);
            if (ok)
                return true;
            err = typeName(in_.kind) ~ " (" ~ toJson(in_) ~ ") has no keys";
            return false;
        }
    case Builtin.type:
        r = Value.string_(typeName(in_.kind));
        return true;
    case Builtin.add:
        {
            bool ok;
            auto xs = valuesOf(in_, ok);
            if (!ok)
            {
                err = "Cannot iterate over " ~ typeName(in_.kind);
                return false;
            }
            return addAll(xs, r, err);
        }
    case Builtin.sort:
        if (in_.kind != Kind.array)
        {
            err = typeName(in_.kind) ~ " (" ~ toJson(in_) ~ ") cannot be sorted, as it is not an array";
            return false;
        }
        r = gather(in_.items, sortedByValue(in_.items));
        return true;
    case Builtin.unique:
        {
            if (in_.kind != Kind.array)
            {
                err = typeName(in_.kind) ~ " (" ~ toJson(in_) ~ ") cannot be sorted, as it is not an array";
                return false;
            }
            auto items = in_.items;
            auto order = sortedByValue(items);
            Appender!(Value[]) app;
            foreach (i, p; order)
                if (i == 0 || compare(items[order[i - 1]], items[p]) != 0)
                    app.put(items[p]);
            r = Value.array(app.data);
            return true;
        }
    case Builtin.reverse:
        if (reverseOp(in_, r))
            return true;
        err = "Cannot reverse " ~ typeName(in_.kind);
        return false;
    case Builtin.min:
    case Builtin.max:
        {
            if (in_.kind != Kind.array)
            {
                err = typeName(in_.kind) ~ " (" ~ toJson(in_) ~ ") cannot be iterated over";
                return false;
            }
            auto items = in_.items;
            if (items.length == 0)
            {
                r = Value.nullValue;
                return true;
            }
            Value best = items[0];
            foreach (x; items[1 .. $])
            {
                immutable c = compare(x, best);
                if (fn == Builtin.min ? c < 0 : c >= 0)
                    best = x;
            }
            r = best;
            return true;
        }
    case Builtin.tostring:
        r = in_.kind == Kind.string_ ? in_ : Value.string_(toJson(in_));
        return true;
    case Builtin.tonumber:
        if (tonumberOp(in_, r))
            return true;
        err = "Cannot parse " ~ typeName(in_.kind) ~ " as a number";
        return false;
    case Builtin.empty:
    case Builtin.error:
    case Builtin.has:
    case Builtin.select:
    case Builtin.map:
    case Builtin.sortBy:
    case Builtin.groupBy:
        assert(false, "not a nullary builtin");
    }
}

/// The evaluator. One instance per $(LREF Program); not thread-safe.
final class Interpreter
{
    /// Set when a raised error is pending (i.e. evaluation aborted because of an error).
    bool hasError;
    /// Description of the pending error.
    string errorMessage;
    /// Value of the pending error.
    Value errorValue;

    private bool raise(string msg)
    {
        hasError = true;
        errorMessage = msg;
        errorValue = Value.string_(msg);
        return false;
    }

    private bool raiseValue(Value v)
    {
        hasError = true;
        errorValue = v;
        errorMessage = v.kind == Kind.string_ ? v.str : toJson(v) ~ " (not a string)";
        return false;
    }

    /// Evaluate a node that always yields exactly one output (see `Node.simple`).
    bool evalSimple(Node n, Value input, Env* env, out Value r)
    {
        final switch (n.kind)
        {
        case NodeKind.identity:
            r = input;
            return true;
        case NodeKind.literal:
            r = n.lit;
            return true;
        case NodeKind.variable:
            r = lookupVar(env, n.depth);
            return true;
        case NodeKind.field:
            {
                Value t;
                if (!evalSimple(n.a, input, env, t))
                    return false;
                return fieldOp(t, n.name, r);
            }
        case NodeKind.index:
            {
                Value t, k;
                if (!evalSimple(n.b, input, env, k) || !evalSimple(n.a, input, env, t))
                    return false;
                if (indexOp(t, k, r))
                    return true;
                return raise(indexErr(t, k));
            }
        case NodeKind.neg:
            {
                Value t;
                if (!evalSimple(n.a, input, env, t))
                    return false;
                return negOp(t, r);
            }
        case NodeKind.binary:
            {
                Value a, b;
                if (!evalSimple(n.b, input, env, b) || !evalSimple(n.a, input, env, a))
                    return false;
                string err;
                if (binaryOp(n.op, a, b, r, err))
                    return true;
                return raise(err);
            }
        case NodeKind.and:
        case NodeKind.or:
            {
                Value a, b;
                if (!evalSimple(n.a, input, env, a))
                    return false;
                immutable isAnd = n.kind == NodeKind.and;
                if (a.truthy != isAnd)
                {
                    r = Value.boolean(!isAnd);
                    return true;
                }
                if (!evalSimple(n.b, input, env, b))
                    return false;
                r = Value.boolean(b.truthy);
                return true;
            }
        case NodeKind.pipe:
            {
                Value mid;
                if (!evalSimple(n.a, input, env, mid))
                    return false;
                return evalSimple(n.b, mid, env, r);
            }
        case NodeKind.ifElse:
            {
                Value c;
                if (!evalSimple(n.a, input, env, c))
                    return false;
                return evalSimple(c.truthy ? n.b : n.c, input, env, r);
            }
        case NodeKind.call:
            {
                string err;
                if (callNullary(n.fn, input, r, err))
                    return true;
                return raise(err);
            }
        case NodeKind.slice:
        case NodeKind.iterate:
        case NodeKind.tryOp:
        case NodeKind.comma:
        case NodeKind.collect:
        case NodeKind.object:
        case NodeKind.asBind:
        case NodeKind.reduce:
            assert(false, "not a simple node");
        }
    }

    private bool fieldOp(Value t, JStr name, out Value r)
    {
        if (t.kind == Kind.object)
        {
            bool found;
            r = t.obj.get(name, found);
            return true;
        }
        if (t.kind == Kind.null_)
        {
            r = Value.nullValue;
            return true;
        }
        return raise("Cannot index " ~ typeName(t.kind) ~ " with \"" ~ name.s ~ "\"");
    }

    private bool negOp(Value t, out Value r)
    {
        if (t.kind != Kind.number)
            return raise(typeName(t.kind) ~ " (" ~ toJson(t) ~ ") cannot be negated");
        r = Value.number(-t.num);
        return true;
    }

    private bool iterateOp(Value t, bool opt, scope Sink sink)
    {
        if (t.kind == Kind.array)
        {
            foreach (x; t.items)
                if (!sink(x))
                    return false;
            return true;
        }
        if (t.kind == Kind.object)
        {
            foreach (ref e; t.obj.entries)
                if (!sink(e.val))
                    return false;
            return true;
        }
        if (opt)
            return true;
        return raise("Cannot iterate over " ~ typeName(t.kind));
    }

    /// Evaluate `n` on `input`, calling `sink` for each output.
    bool eval(Node n, Value input, Env* env, scope Sink sink)
    {
        if (n.simple)
        {
            Value r;
            if (!evalSimple(n, input, env, r))
                return false;
            return sink(r);
        }
        final switch (n.kind)
        {
        case NodeKind.identity:
        case NodeKind.literal:
        case NodeKind.variable:
            assert(false, "simple");
        case NodeKind.field:
            if (n.a.kind == NodeKind.identity)
            {
                Value r;
                if (!fieldOp(input, n.name, r))
                {
                    if (n.opt)
                    {
                        hasError = false;
                        return true;
                    }
                    return false;
                }
                return sink(r);
            }
            return eval(n.a, input, env, (Value t) {
                Value r;
                if (t.kind == Kind.object)
                {
                    bool found;
                    r = t.obj.get(n.name, found);
                }
                else if (t.kind == Kind.null_)
                    r = Value.nullValue;
                else if (n.opt)
                    return true;
                else
                    return raise("Cannot index " ~ typeName(t.kind) ~ " with \"" ~ n.name.s ~ "\"");
                return sink(r);
            });
        case NodeKind.index:
            return eval(n.b, input, env, (Value k) {
                return eval(n.a, input, env, (Value t) {
                    Value r;
                    if (!indexOp(t, k, r))
                    {
                        if (n.opt)
                            return true;
                        return raise(indexErr(t, k));
                    }
                    return sink(r);
                });
            });
        case NodeKind.slice:
            return evalOptional(n.b, input, env, (Value from) {
                return evalOptional(n.c, input, env, (Value to) {
                    return eval(n.a, input, env, (Value t) {
                        Value r;
                        if (!sliceOp(t, from, to, r))
                        {
                            if (n.opt)
                                return true;
                            return raise(sliceErr(t));
                        }
                        return sink(r);
                    });
                });
            });
        case NodeKind.iterate:
            if (n.a.kind == NodeKind.identity)
                return iterateOp(input, n.opt, sink);
            return eval(n.a, input, env, (Value t) => iterateOp(t, n.opt, sink));
        case NodeKind.tryOp:
            {
                bool downstream = false;
                immutable ok = eval(n.a, input, env, (Value v) {
                    if (!sink(v))
                    {
                        downstream = true;
                        return false;
                    }
                    return true;
                });
                if (!ok && !downstream)
                {
                    hasError = false; // the error was raised inside the term: swallow it
                    return true;
                }
                return ok;
            }
        case NodeKind.neg:
            return eval(n.a, input, env, (Value t) {
                Value r;
                if (!negOp(t, r))
                    return false;
                return sink(r);
            });
        case NodeKind.binary:
            {
                if (n.b.simple)
                {
                    Value b;
                    if (!evalSimple(n.b, input, env, b))
                        return false;
                    return binaryRight(n, b, input, env, sink);
                }
                return eval(n.b, input, env, (Value b) => binaryRight(n, b, input, env, sink));
            }
        case NodeKind.and:
            return eval(n.a, input, env, (Value a) {
                if (!a.truthy)
                    return sink(Value.boolean(false));
                return eval(n.b, input, env, (Value b) => sink(Value.boolean(b.truthy)));
            });
        case NodeKind.or:
            return eval(n.a, input, env, (Value a) {
                if (a.truthy)
                    return sink(Value.boolean(true));
                return eval(n.b, input, env, (Value b) => sink(Value.boolean(b.truthy)));
            });
        case NodeKind.pipe:
            return eval(n.a, input, env, (Value v) => eval(n.b, v, env, sink));
        case NodeKind.comma:
            return eval(n.a, input, env, sink) && eval(n.b, input, env, sink);
        case NodeKind.collect:
            {
                Appender!(Value[]) app;
                if (n.a !is null && !eval(n.a, input, env, (Value v) { app.put(v); return true; }))
                    return false;
                return sink(Value.array(app.data));
            }
        case NodeKind.object:
            return evalObject(n, input, env, sink);
        case NodeKind.ifElse:
            return eval(n.a, input, env, (Value c) => eval(c.truthy ? n.b : n.c, input, env, sink));
        case NodeKind.asBind:
            return eval(n.a, input, env, (Value v) {
                Env e = Env(env, v);
                return eval(n.b, input, &e, sink);
            });
        case NodeKind.reduce:
            return eval(n.b, input, env, (Value init) {
                Value acc = init;
                if (!eval(n.a, input, env, (Value v) {
                        Env e = Env(env, v);
                        Value last;
                        if (!eval(n.c, acc, &e, (Value u) { last = u; return true; }))
                            return false;
                        acc = last;
                        return true;
                    }))
                    return false;
                return sink(acc);
            });
        case NodeKind.call:
            return evalCall(n, input, env, sink);
        }
    }

    private bool evalOptional(Node n, Value input, Env* env, scope Sink sink)
    {
        if (n is null)
            return sink(Value.nullValue);
        return eval(n, input, env, sink);
    }

    private bool binaryRight(Node n, Value b, Value input, Env* env, scope Sink sink)
    {
        if (n.a.simple)
        {
            Value a, r;
            string err;
            if (!evalSimple(n.a, input, env, a))
                return false;
            if (!binaryOp(n.op, a, b, r, err))
                return raise(err);
            return sink(r);
        }
        return eval(n.a, input, env, (Value a) {
            Value r;
            string err;
            if (!binaryOp(n.op, a, b, r, err))
                return raise(err);
            return sink(r);
        });
    }

    private bool evalObject(Node n, Value input, Env* env, scope Sink sink)
    {
        immutable k = n.entries.length;
        JStr[8] stackKeys = void;
        Value[8] stackVals = void;
        JStr[] keys = k <= 8 ? stackKeys[0 .. k] : new JStr[](k);
        Value[] vals = k <= 8 ? stackVals[0 .. k] : new Value[](k);
        return objectStep(n, 0, input, env, keys, vals, sink);
    }

    private bool objectStep(Node n, size_t i, Value input, Env* env, JStr[] keys, Value[] vals, scope Sink sink)
    {
        if (i == n.entries.length)
        {
            auto o = new JObject(keys.length);
            if (n.distinctLiteralKeys)
                foreach (j; 0 .. keys.length)
                    o.append(keys[j], vals[j]);
            else
                foreach (j; 0 .. keys.length)
                    o.set(keys[j], vals[j]);
            return sink(Value.object(o));
        }
        auto entry = &n.entries[i];
        bool doValue()
        {
            return eval(entry.val, input, env, (Value v) {
                vals[i] = v;
                return objectStep(n, i + 1, input, env, keys, vals, sink);
            });
        }

        if (entry.key is null)
        {
            keys[i] = entry.litKey;
            return doValue();
        }
        return eval(entry.key, input, env, (Value kv) {
            if (kv.kind != Kind.string_)
                return raise("Object keys must be strings");
            keys[i] = kv.jstr;
            return doValue();
        });
    }

    private bool evalCall(Node n, Value input, Env* env, scope Sink sink)
    {
        final switch (n.fn)
        {
        case Builtin.empty:
            return true;
        case Builtin.error:
            if (n.args.length == 0)
                return raiseValue(input);
            return eval(n.args[0], input, env, (Value v) => raiseValue(v));
        case Builtin.select:
            return eval(n.args[0], input, env, (Value c) {
                if (c.truthy)
                    return sink(input);
                return true;
            });
        case Builtin.map:
            {
                Appender!(Value[]) app;
                if (!iterateOp(input, false, (Value x) => eval(n.args[0], x, env, (Value v) { app.put(v); return true; })))
                    return false;
                return sink(Value.array(app.data));
            }
        case Builtin.has:
            return eval(n.args[0], input, env, (Value k) {
                bool res;
                if (!hasOp(input, k, res))
                    return raise("Cannot check whether " ~ typeName(input.kind) ~ " has a " ~ typeName(k.kind) ~ " key");
                return sink(Value.boolean(res));
            });
        case Builtin.sortBy:
        case Builtin.groupBy:
            {
                if (input.kind != Kind.array)
                    return raise(typeName(input.kind) ~ " (" ~ toJson(input) ~ ") cannot be sorted, as it is not an array");
                auto items = input.items;
                auto keyVals = new Value[](items.length);
                foreach (i, x; items)
                {
                    Appender!(Value[]) app;
                    if (!eval(n.args[0], x, env, (Value v) { app.put(v); return true; }))
                        return false;
                    keyVals[i] = Value.array(app.data);
                }
                auto order = stableOrder(items.length, (a, b) => compare(keyVals[a], keyVals[b]));
                if (n.fn == Builtin.sortBy)
                    return sink(gather(items, order));
                Appender!(Value[]) groups;
                size_t i = 0;
                while (i < order.length)
                {
                    size_t j = i + 1;
                    while (j < order.length && compare(keyVals[order[i]], keyVals[order[j]]) == 0)
                        ++j;
                    auto grp = new Value[](j - i);
                    foreach (q; i .. j)
                        grp[q - i] = items[order[q]];
                    groups.put(Value.array(grp));
                    i = j;
                }
                return sink(Value.array(groups.data));
            }
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
            assert(false, "nullary builtins are simple nodes");
        }
    }
}
