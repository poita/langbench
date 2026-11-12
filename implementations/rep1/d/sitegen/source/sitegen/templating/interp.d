/**
 * The template interpreter: a tree walker over parsed templates, with a chain
 * of lexical scopes, macros, includes and block inheritance.
 */
module sitegen.templating.interp;

import std.array : Appender, appender;
import std.math : floor, fmod, pow;
import sitegen.templating.ast;
import sitegen.templating.errors;
import sitegen.templating.filters;
import sitegen.templating.value;

/// A lexical scope.  Creating one costs O(1); a lookup walks the chain.
final class Scope
{
    Scope parent;
    private string name0, name1;
    private Value val0, val1;
    private size_t count;
    private string[] moreNames;
    private Value[] moreVals;

    ///
    this(Scope parent = null)
    {
        this.parent = parent;
    }

    /// Binds `name` in this scope (not in an ancestor).
    void set(string name, Value v)
    {
        if (count > 0 && name0 == name)
        {
            val0 = v;
            return;
        }
        if (count > 1 && name1 == name)
        {
            val1 = v;
            return;
        }
        foreach (idx, n; moreNames)
        {
            if (n == name)
            {
                moreVals[idx] = v;
                return;
            }
        }
        if (count == 0)
        {
            name0 = name;
            val0 = v;
            count = 1;
        }
        else if (count == 1)
        {
            name1 = name;
            val1 = v;
            count = 2;
        }
        else
        {
            moreNames ~= name;
            moreVals ~= v;
        }
    }

    /// Looks `name` up in this scope and its ancestors.
    bool find(string name, out Value v)
    {
        for (Scope s = this; s !is null; s = s.parent)
        {
            if (s.count > 0 && s.name0 == name)
            {
                v = s.val0;
                return true;
            }
            if (s.count > 1 && s.name1 == name)
            {
                v = s.val1;
                return true;
            }
            foreach_reverse (idx, n; s.moreNames)
            {
                if (n == name)
                {
                    v = s.moreVals[idx];
                    return true;
                }
            }
        }
        return false;
    }
}

/// Supplies loaded templates to the interpreter.
interface TemplateLoader
{
    /// Whether a template of that name exists.
    bool hasTemplate(string name);
    /// Loads (parses and checks, at most once) the named template.
    Template load(string name);
}

/// The state of one rendering of a template (the main one, or one `include`).
private final class Rendering
{
    Scope tscope;
    /// For each block name, the chain of bodies, most derived first.
    Node[][string] chains;
    /// The parent template named by an executed `extends`, until its body runs.
    Template pendingParent;
}

/// Where output goes, and whether it is currently suppressed.
private final class Output
{
    Appender!string* buf;
    bool suppressed;

    this(Appender!string* buf)
    {
        this.buf = buf;
    }
}

private final class Macro : Callable
{
    Node node;
    Scope defScope;
    Rendering rendering;
}

private final class SuperFn : Callable
{
    Rendering rendering;
    string block;
    size_t index;
}

private final class RangeFn : Callable
{
}

/// Renders templates.
final class Interpreter
{
    private TemplateLoader loader;
    private RangeFn rangeFn;
    private int depth;

    ///
    this(TemplateLoader loader)
    {
        this.loader = loader;
        rangeFn = new RangeFn;
    }

    /**
     * Renders the template `name` in a root scope holding `context`.
     *
     * Throws: `TemplateException`
     */
    string render(string name, Value[string] context)
    {
        auto root = new Scope;
        foreach (k, v; context) root.set(k, v);
        auto tmpl = loader.load(name);
        Appender!string buf;
        auto out_ = new Output(&buf);
        runTemplate(tmpl, root, out_);
        return buf.data;
    }

    private void runTemplate(Template t, Scope parentScope, Output out_)
    {
        auto r = new Rendering;
        r.tscope = new Scope(parentScope);
        foreach (n, b; t.blocks) r.chains[n] = [b];
        runBody(t, r, out_);
    }

    private void runBody(Template t, Rendering r, Output out_)
    {
        exec(t.body_, r.tscope, out_, r);
        if (r.pendingParent !is null)
        {
            auto parent = r.pendingParent;
            r.pendingParent = null;
            out_.suppressed = false;
            runBody(parent, r, out_);
        }
    }

    // ------------------------------------------------------------------
    // Statements
    // ------------------------------------------------------------------

    private void exec(Node[] nodes, Scope sc, Output out_, Rendering r)
    {
        foreach (n; nodes)
        {
            final switch (n.kind)
            {
                case NodeKind.text:
                    if (!out_.suppressed) out_.buf.put(n.text);
                    break;
                case NodeKind.print:
                    if (!out_.suppressed) appendDisplay(*out_.buf, eval(n.expr, sc));
                    break;
                case NodeKind.if_:
                    {
                        bool done = false;
                        foreach (idx, c; n.conds)
                        {
                            if (truthy(eval(c, sc)))
                            {
                                exec(n.bodies[idx], sc, out_, r);
                                done = true;
                                break;
                            }
                        }
                        if (!done) exec(n.elseBody, sc, out_, r);
                    }
                    break;
                case NodeKind.for_:
                    execFor(n, sc, out_, r);
                    break;
                case NodeKind.set:
                    sc.set(n.name, eval(n.expr, sc));
                    break;
                case NodeKind.macro_:
                    {
                        auto m = new Macro;
                        m.node = n;
                        m.defScope = sc;
                        m.rendering = r;
                        sc.set(n.name, Value.callable(m));
                    }
                    break;
                case NodeKind.include:
                    {
                        if (out_.suppressed) break;
                        auto tmpl = loadNamed(eval(n.expr, sc));
                        if (++depth > 50) typeError("templates nested too deeply");
                        scope (exit) depth--;
                        auto sub = new Output(out_.buf);
                        runTemplate(tmpl, sc, sub);
                    }
                    break;
                case NodeKind.extends:
                    {
                        auto parent = loadNamed(eval(n.expr, sc));
                        foreach (name, b; parent.blocks)
                            r.chains[name] = r.chains.get(name, null) ~ b;
                        r.pendingParent = parent;
                        out_.suppressed = true;
                    }
                    break;
                case NodeKind.block:
                    if (!out_.suppressed) renderBlock(r, n.name, 0, out_);
                    break;
            }
        }
    }

    private Template loadNamed(Value name)
    {
        if (name.isUndefined) undefinedError("template name is undefined");
        if (name.kind != Kind.string_) typeError("template name must be a string");
        if (!loader.hasTemplate(name.s)) templateError("no template named " ~ name.s);
        return loader.load(name.s);
    }

    private void renderBlock(Rendering r, string name, size_t index, Output out_)
    {
        auto chain = name in r.chains;
        if (chain is null || index >= chain.length) undefinedError("no block " ~ name);
        auto bs = new Scope(r.tscope);
        auto sf = new SuperFn;
        sf.rendering = r;
        sf.block = name;
        sf.index = index;
        bs.set("super", Value.callable(sf));
        exec((*chain)[index].body_, bs, out_, r);
    }

    private void execFor(Node n, Scope sc, Output out_, Rendering r)
    {
        auto seq = sequenceOf(eval(n.expr, sc));
        if (seq.length == 0)
        {
            exec(n.elseBody, sc, out_, r);
            return;
        }
        Value loop;
        loop.kind = Kind.loop;
        loop.loopLength = cast(long) seq.length;
        foreach (idx, item; seq)
        {
            loop.i = cast(long) idx;
            auto is_ = new Scope(sc);
            is_.set(n.name, item);
            is_.set("loop", loop);
            exec(n.body_, is_, out_, r);
        }
    }

    // ------------------------------------------------------------------
    // Expressions
    // ------------------------------------------------------------------

    Value eval(Expr e, Scope sc)
    {
        final switch (e.kind)
        {
            case ExprKind.intLit:
                return Value.integer(e.ival);
            case ExprKind.floatLit:
                return Value.floating(e.fval);
            case ExprKind.strLit:
                return Value.str(e.str);
            case ExprKind.boolLit:
                return Value.boolean(e.flag);
            case ExprKind.noneLit:
                return Value.none;
            case ExprKind.name:
                {
                    Value v;
                    if (sc.find(e.str, v)) return v;
                    if (e.str == "range") return Value.callable(rangeFn);
                    return Value.undefined;
                }
            case ExprKind.list:
                {
                    auto items = new Value[e.args.length];
                    foreach (idx, a; e.args) items[idx] = eval(a, sc);
                    return Value.list(items);
                }
            case ExprKind.neg:
                {
                    auto v = eval(e.a, sc);
                    if (v.isUndefined) undefinedError("negating the undefined value");
                    if (v.isIntegral) return Value.integer(-v.i);
                    if (v.kind == Kind.floating) return Value.floating(-v.f);
                    typeError("cannot negate a non-number");
                }
            case ExprKind.not:
                return Value.boolean(!truthy(eval(e.a, sc)));
            case ExprKind.and:
                {
                    auto l = eval(e.a, sc);
                    if (!truthy(l)) return l;
                    return eval(e.b, sc);
                }
            case ExprKind.or:
                {
                    auto l = eval(e.a, sc);
                    if (truthy(l)) return l;
                    return eval(e.b, sc);
                }
            case ExprKind.binary:
                {
                    auto l = eval(e.a, sc);
                    auto rr = eval(e.b, sc);
                    return binary(e.binOp, l, rr);
                }
            case ExprKind.compare:
                return evalCompare(e, sc);
            case ExprKind.filter:
                {
                    auto input = eval(e.a, sc);
                    auto args = new Value[e.args.length];
                    foreach (idx, a; e.args) args[idx] = eval(a, sc);
                    return applyFilter(e.str, input, args);
                }
            case ExprKind.isDefined:
                {
                    auto v = eval(e.a, sc);
                    return Value.boolean(v.isUndefined == e.flag);
                }
            case ExprKind.attr:
                {
                    auto base = eval(e.a, sc);
                    return getItem(base, Value.str(e.str));
                }
            case ExprKind.index:
                {
                    auto base = eval(e.a, sc);
                    auto key = eval(e.b, sc);
                    return getItem(base, key);
                }
            case ExprKind.call:
                return evalCall(e, sc);
        }
    }

    private static Value getItem(Value base, Value key)
    {
        if (base.isUndefined) undefinedError("attribute access on the undefined value");
        if (key.isUndefined) undefinedError("undefined subscript");
        switch (base.kind)
        {
            case Kind.dict:
                if (key.kind == Kind.string_)
                {
                    Value v;
                    if (base.d.get(key.s, v)) return v;
                }
                return Value.undefined;
            case Kind.list:
                if (key.isIntegral)
                {
                    long i = key.i;
                    const n = cast(long) base.l.length;
                    if (i < 0) i += n;
                    if (i >= 0 && i < n) return base.l[cast(size_t) i];
                }
                return Value.undefined;
            case Kind.string_:
                if (key.isIntegral)
                {
                    long i = key.i;
                    const n = cast(long) codePointCount(base.s);
                    if (i < 0) i += n;
                    if (i >= 0 && i < n)
                    {
                        // O(i): walk to the i-th code point.
                        size_t pos = 0;
                        foreach (_; 0 .. cast(size_t) i) pos += utf8Length(base.s[pos]);
                        const len = utf8Length(base.s[pos]);
                        return Value.str(base.s[pos .. pos + len]);
                    }
                }
                return Value.undefined;
            case Kind.loop:
                if (key.kind == Kind.string_)
                {
                    switch (key.s)
                    {
                        case "index": return Value.integer(base.i + 1);
                        case "index0": return Value.integer(base.i);
                        case "first": return Value.boolean(base.i == 0);
                        case "last": return Value.boolean(base.i + 1 == base.loopLength);
                        case "length": return Value.integer(base.loopLength);
                        default: break;
                    }
                }
                return Value.undefined;
            default:
                return Value.undefined;
        }
    }

    private Value evalCompare(Expr e, Scope sc)
    {
        auto left = eval(e.args[0], sc);
        foreach (idx, op; e.cmpOps)
        {
            auto right = eval(e.args[idx + 1], sc);
            if (!compareValues(op, left, right)) return Value.boolean(false);
            left = right;
        }
        return Value.boolean(true);
    }

    private static bool compareValues(CmpOp op, Value a, Value b)
    {
        if (a.isUndefined || b.isUndefined) undefinedError("comparison with the undefined value");
        final switch (op)
        {
            case CmpOp.eq:
                return valuesEqual(a, b);
            case CmpOp.ne:
                return !valuesEqual(a, b);
            case CmpOp.lt, CmpOp.le, CmpOp.gt, CmpOp.ge:
                {
                    int c;
                    if (a.isNumber && b.isNumber)
                    {
                        if (a.isIntegral && b.isIntegral)
                            c = a.i < b.i ? -1 : a.i > b.i ? 1 : 0;
                        else
                        {
                            const x = a.asDouble, y = b.asDouble;
                            // Comparisons with NaN are all false; floats are never NaN here.
                            c = x < y ? -1 : x > y ? 1 : 0;
                        }
                    }
                    else if (a.kind == Kind.string_ && b.kind == Kind.string_)
                        c = a.s < b.s ? -1 : a.s > b.s ? 1 : 0;
                    else
                        typeError("values cannot be ordered");
                    switch (op)
                    {
                        case CmpOp.lt: return c < 0;
                        case CmpOp.le: return c <= 0;
                        case CmpOp.gt: return c > 0;
                        default: return c >= 0;
                    }
                }
            case CmpOp.in_:
                return contains(b, a);
            case CmpOp.notIn:
                return !contains(b, a);
        }
    }

    private static bool contains(Value container, Value item)
    {
        import std.string : indexOf;

        switch (container.kind)
        {
            case Kind.string_:
                if (item.kind != Kind.string_) typeError("'in <string>' requires a string");
                return item.s.length == 0 || container.s.indexOf(item.s) >= 0;
            case Kind.dict:
                return item.kind == Kind.string_ && container.d.contains(item.s);
            case Kind.list:
                foreach (ref x; container.l)
                    if (valuesEqual(x, item)) return true;
                return false;
            default:
                typeError("right operand of 'in' is not a container");
        }
    }

    // ------------------------------------------------------------------
    // Arithmetic
    // ------------------------------------------------------------------

    private static Value binary(BinOp op, Value a, Value b)
    {
        if (a.isUndefined || b.isUndefined) undefinedError("operator applied to the undefined value");
        final switch (op)
        {
            case BinOp.concat:
                {
                    auto o = appender!string();
                    appendDisplay(o, a);
                    appendDisplay(o, b);
                    return Value.str(o.data);
                }
            case BinOp.add:
                if (a.isNumber && b.isNumber)
                {
                    if (a.isIntegral && b.isIntegral) return Value.integer(a.i + b.i);
                    return Value.floating(a.asDouble + b.asDouble);
                }
                if (a.kind == Kind.string_ && b.kind == Kind.string_) return Value.str(a.s ~ b.s);
                if (a.kind == Kind.list && b.kind == Kind.list) return Value.list(a.l ~ b.l);
                typeError("cannot add these values");
            case BinOp.sub:
                if (a.isNumber && b.isNumber)
                {
                    if (a.isIntegral && b.isIntegral) return Value.integer(a.i - b.i);
                    return Value.floating(a.asDouble - b.asDouble);
                }
                typeError("cannot subtract these values");
            case BinOp.mul:
                if (a.isNumber && b.isNumber)
                {
                    if (a.isIntegral && b.isIntegral) return Value.integer(a.i * b.i);
                    return Value.floating(a.asDouble * b.asDouble);
                }
                if (a.kind == Kind.string_ && b.isIntegral) return repeat(a.s, b.i);
                if (b.kind == Kind.string_ && a.isIntegral) return repeat(b.s, a.i);
                typeError("cannot multiply these values");
            case BinOp.div:
                if (a.isNumber && b.isNumber)
                {
                    const y = b.asDouble;
                    if (y == 0) typeError("division by zero");
                    return Value.floating(a.asDouble / y);
                }
                typeError("cannot divide these values");
            case BinOp.floorDiv:
                if (a.isNumber && b.isNumber)
                {
                    if (a.isIntegral && b.isIntegral)
                    {
                        if (b.i == 0) typeError("division by zero");
                        long q = a.i / b.i;
                        if ((a.i % b.i != 0) && ((a.i < 0) != (b.i < 0))) q--;
                        return Value.integer(q);
                    }
                    const y = b.asDouble;
                    if (y == 0) typeError("division by zero");
                    return Value.floating(floor(a.asDouble / y));
                }
                typeError("cannot divide these values");
            case BinOp.mod:
                if (a.isNumber && b.isNumber)
                {
                    if (a.isIntegral && b.isIntegral)
                    {
                        if (b.i == 0) typeError("modulo by zero");
                        long m = a.i % b.i;
                        if (m != 0 && ((m < 0) != (b.i < 0))) m += b.i;
                        return Value.integer(m);
                    }
                    const y = b.asDouble;
                    if (y == 0) typeError("modulo by zero");
                    double m = fmod(a.asDouble, y);
                    if (m != 0 && ((m < 0) != (y < 0))) m += y;
                    return Value.floating(m);
                }
                typeError("cannot take the modulo of these values");
            case BinOp.pow:
                if (a.isNumber && b.isNumber)
                {
                    if (a.isIntegral && b.isIntegral)
                    {
                        if (b.i >= 0)
                        {
                            long result = 1;
                            foreach (_; 0 .. b.i) result *= a.i;
                            return Value.integer(result);
                        }
                        if (a.i == 0) typeError("zero to a negative power");
                        return Value.floating(pow(cast(double) a.i, cast(double) b.i));
                    }
                    const x = a.asDouble, y = b.asDouble;
                    if (x == 0 && y < 0) typeError("zero to a negative power");
                    return Value.floating(pow(x, y));
                }
                typeError("cannot exponentiate these values");
        }
    }

    private static Value repeat(string s, long n)
    {
        if (n <= 0 || s.length == 0) return Value.str("");
        auto o = appender!string();
        o.reserve(s.length * cast(size_t) n);
        foreach (_; 0 .. n) o.put(s);
        return Value.str(o.data);
    }

    // ------------------------------------------------------------------
    // Calls
    // ------------------------------------------------------------------

    private Value evalCall(Expr e, Scope sc)
    {
        auto callee = eval(e.a, sc);
        auto args = new Value[e.args.length];
        foreach (idx, a; e.args) args[idx] = eval(a, sc);
        auto kwValues = new Value[e.kwValues.length];
        foreach (idx, a; e.kwValues) kwValues[idx] = eval(a, sc);

        if (callee.isUndefined) undefinedError("calling the undefined value");
        if (callee.kind != Kind.callable) typeError("value is not callable");
        if (auto m = cast(Macro) callee.c) return callMacro(m, args, e.kwNames, kwValues);
        if (auto s = cast(SuperFn) callee.c)
        {
            if (args.length || kwValues.length) typeError("super() takes no arguments");
            auto buf = appender!string();
            auto o = new Output(&buf);
            renderBlock(s.rendering, s.block, s.index + 1, o);
            return Value.str(buf.data);
        }
        return callRange(args, kwValues);
    }

    private static Value callRange(Value[] args, Value[] kwValues)
    {
        if (kwValues.length) typeError("range takes no keyword arguments");
        if (args.length < 1 || args.length > 3) typeError("range takes one to three arguments");
        long[3] n;
        foreach (idx, a; args)
        {
            if (a.isUndefined) undefinedError("range argument is undefined");
            if (!a.isIntegral) typeError("range arguments must be integers");
            n[idx] = a.i;
        }
        long start = 0, stop, step = 1;
        if (args.length == 1)
            stop = n[0];
        else
        {
            start = n[0];
            stop = n[1];
            if (args.length == 3) step = n[2];
        }
        if (step == 0) typeError("range step is zero");
        Value[] items;
        if (step > 0)
        {
            if (stop > start) items.reserve(cast(size_t)((stop - start + step - 1) / step));
            for (long i = start; i < stop; i += step) items ~= Value.integer(i);
        }
        else
        {
            for (long i = start; i > stop; i += step) items ~= Value.integer(i);
        }
        return Value.list(items);
    }

    private Value callMacro(Macro m, Value[] args, string[] kwNames, Value[] kwValues)
    {
        auto params = m.node.params;
        if (args.length > params.length) typeError("too many arguments to macro");
        if (++depth > 400) typeError("macro recursion too deep");
        scope (exit) depth--;
        auto ms = new Scope(m.defScope);
        auto bound = new bool[params.length];
        foreach (idx, a; args)
        {
            ms.set(params[idx].name, a);
            bound[idx] = true;
        }
        foreach (idx, k; kwNames)
        {
            size_t at = size_t.max;
            foreach (pi, p; params)
                if (p.name == k)
                {
                    at = pi;
                    break;
                }
            if (at == size_t.max || bound[at]) typeError("bad keyword argument " ~ k);
            ms.set(k, kwValues[idx]);
            bound[at] = true;
        }
        foreach (idx, p; params)
        {
            if (bound[idx]) continue;
            ms.set(p.name, p.defaultValue !is null ? eval(p.defaultValue, ms) : Value.undefined);
        }
        auto buf = appender!string();
        auto o = new Output(&buf);
        exec(m.node.body_, ms, o, m.rendering);
        return Value.str(buf.data);
    }
}
