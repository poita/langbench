/// The template interpreter: template loading and caching, expression
/// evaluation, statement execution, macros and block inheritance.
module sitegen.templating.engine;

import sitegen.templating.ast;
import sitegen.templating.errors;
import sitegen.templating.filters;
import sitegen.templating.ops;
import sitegen.templating.parser;
import sitegen.templating.scopes;
import sitegen.templating.value;
import std.array : Appender, appender;

/// Callback that supplies template source by name. Returns false when no
/// template of that name exists.
alias TemplateLoader = bool delegate(string name, out string source);

/// The output buffer all rendering appends to.
private final class Buf
{
    Appender!(char[]) app;
}

/// State of one rendering (the main template, or one `include`): its template
/// scope and, per block name, the chain of bodies from most to least derived.
private final class Rendering
{
    Scope tscope;
    Stmt[][string] chains;
}

/// Loads templates through a `TemplateLoader`, caches them parsed, and renders
/// them.
///
/// ---
/// auto engine = new Engine((string name, out string src) {
///     if (name != "main") return false;
///     src = "Hello {{ who|upper }}!";
///     return true;
/// });
/// auto root = new Scope();
/// root.set("who", Value.of("world"));
/// assert(engine.render("main", root) == "Hello WORLD!");
/// ---
final class Engine
{
    private TemplateLoader loader;
    private Template[string] cache;

    this(TemplateLoader loader)
    {
        this.loader = loader;
    }

    /// Load (parse and check) the template `name`; cached after the first success.
    Template load(string name)
    {
        if (auto t = name in cache)
            return *t;
        string source;
        if (!loader(name, source))
            throw new TemplateError(ErrorKind.template_, "no template named '" ~ name ~ "'");
        auto t = parseTemplate(name, source);
        cache[name] = t;
        return t;
    }

    /// Render template `entry` with `root` as the root scope.
    /// Throws `TemplateError` on any failure.
    string render(string entry, Scope root)
    {
        auto t = load(entry);
        auto buf = new Buf;
        renderTemplate(t, root, buf);
        return buf.app.data.idup;
    }

    // ------------------------------------------------------------------
    // templates and blocks

    private void renderTemplate(Template t, Scope parent, Buf buf)
    {
        auto r = new Rendering;
        r.tscope = new Scope(parent);
        foreach (b; t.blocks)
            r.chains[b.name] ~= b;
        Template cur = t;
        while (cur !is null)
            cur = executeTop(cur, r, buf);
    }

    /// Run a template's top-level statements; returns the parent template if
    /// an `extends` tag ran.
    private Template executeTop(Template t, Rendering r, Buf buf)
    {
        Template parent;
        bool extended = false;
        foreach (st; t.body_)
        {
            if (st.kind == StmtKind.extends)
            {
                Value nv = eval(st.expr, r.tscope);
                parent = load(templateName(nv));
                foreach (b; parent.blocks)
                    r.chains[b.name] ~= b;
                extended = true;
                continue;
            }
            if (extended && st.kind != StmtKind.set && st.kind != StmtKind.macroDef)
                continue;
            execute(st, r.tscope, r, buf);
        }
        return parent;
    }

    private string templateName(Value v)
    {
        if (v.isUndefined)
            throw undefinedError("undefined template name");
        if (v.kind != Kind.text)
            throw typeError("template name must be a string");
        return v.s;
    }

    private void executeBlock(Rendering r, string name, size_t index, Buf buf)
    {
        auto chain = r.chains[name];
        auto scope_ = new Scope(r.tscope);
        Value sv;
        sv.kind = Kind.superFn;
        sv.o = new SuperObj(r, name, index);
        scope_.add("super", sv);
        executeAll(chain[index].body_, scope_, r, buf);
    }

    // ------------------------------------------------------------------
    // statements

    private void executeAll(Stmt[] stmts, Scope sc, Rendering r, Buf buf)
    {
        foreach (st; stmts)
            execute(st, sc, r, buf);
    }

    private void execute(Stmt st, Scope sc, Rendering r, Buf buf)
    {
        final switch (st.kind)
        {
        case StmtKind.text:
            buf.app.put(st.text);
            break;
        case StmtKind.print:
        {
            Value v = eval(st.expr, sc);
            if (v.isUndefined)
                throw undefinedError("printing undefined");
            if (v.kind == Kind.text)
                buf.app.put(v.s);
            else
                putDisplay(buf.app, v);
            break;
        }
        case StmtKind.if_:
        {
            foreach (k, cond; st.conds)
            {
                if (truthy(eval(cond, sc)))
                {
                    executeAll(st.bodies[k], sc, r, buf);
                    return;
                }
            }
            executeAll(st.elseBody, sc, r, buf);
            break;
        }
        case StmtKind.for_:
        {
            Value iterable = eval(st.expr, sc);
            Value[] seq = sequenceView(iterable);
            if (seq.length == 0)
            {
                executeAll(st.elseBody, sc, r, buf);
                break;
            }
            Value loopValue;
            loopValue.kind = Kind.loop;
            loopValue.aux = cast(long) seq.length;
            foreach (k, item; seq)
            {
                loopValue.i = cast(long) k;
                auto iteration = new Scope(sc);
                iteration.add(st.name, item);
                iteration.add("loop", loopValue);
                executeAll(st.body_, iteration, r, buf);
            }
            break;
        }
        case StmtKind.set:
            sc.set(st.name, eval(st.expr, sc));
            break;
        case StmtKind.macroDef:
        {
            Value mv;
            mv.kind = Kind.macroDef;
            mv.o = new MacroObj(st, sc, r);
            sc.set(st.name, mv);
            break;
        }
        case StmtKind.include:
        {
            Value nv = eval(st.expr, sc);
            auto t = load(templateName(nv));
            renderTemplate(t, sc, buf);
            break;
        }
        case StmtKind.extends:
            break; // handled in executeTop
        case StmtKind.block:
            executeBlock(r, st.name, 0, buf);
            break;
        }
    }

    // ------------------------------------------------------------------
    // expressions

    private Value eval(Expr e, Scope sc)
    {
        final switch (e.kind)
        {
        case ExprKind.literal:
            return e.lit;
        case ExprKind.name:
        {
            Value v;
            if (sc.lookup(e.name, v))
                return v;
            if (e.isRangeName)
            {
                Value rv;
                rv.kind = Kind.rangeFn;
                return rv;
            }
            return Value.undefined;
        }
        case ExprKind.attr:
            return getItem(eval(e.a, sc), e.lit);
        case ExprKind.index:
        {
            Value base = eval(e.a, sc);
            Value key = eval(e.b, sc);
            return getItem(base, key);
        }
        case ExprKind.call:
            return evalCall(e, sc);
        case ExprKind.filter:
            return evalFilter(e, sc);
        case ExprKind.isDefined:
        {
            Value v = eval(e.a, sc);
            return Value.of(e.negate ? v.isUndefined : !v.isUndefined);
        }
        case ExprKind.neg:
            return negateValue(eval(e.a, sc));
        case ExprKind.not:
            return Value.of(!truthy(eval(e.a, sc)));
        case ExprKind.binary:
        {
            Value l = eval(e.a, sc);
            Value r = eval(e.b, sc);
            return binaryOp(e.bop, l, r);
        }
        case ExprKind.compare:
        {
            Value left = eval(e.a, sc);
            foreach (k, operand; e.args)
            {
                Value right = eval(operand, sc);
                if (!compareValues(e.cmpOps[k], left, right))
                    return Value.of(false);
                left = right;
            }
            return Value.of(true);
        }
        case ExprKind.and:
        {
            Value l = eval(e.a, sc);
            if (!truthy(l))
                return l;
            return eval(e.b, sc);
        }
        case ExprKind.or:
        {
            Value l = eval(e.a, sc);
            if (truthy(l))
                return l;
            return eval(e.b, sc);
        }
        case ExprKind.list:
        {
            auto items = new Value[e.args.length];
            foreach (k, a; e.args)
                items[k] = eval(a, sc);
            return Value.of(items);
        }
        }
    }

    private Value evalFilter(Expr e, Scope sc)
    {
        Value v = eval(e.a, sc);
        Value[] args;
        if (e.args.length)
        {
            args = new Value[e.args.length];
            foreach (k, a; e.args)
                args[k] = eval(a, sc);
        }
        if (e.filter == FilterId.default_)
        {
            if (args.length > 1)
                throw typeError("default takes at most one argument");
            if (v.isUndefined)
                return args.length ? args[0] : Value.of("");
            return v;
        }
        if (v.isUndefined)
            throw undefinedError("filter applied to undefined");
        return applyFilter(e.filter, v, args);
    }

    private Value evalCall(Expr e, Scope sc)
    {
        Value callee = eval(e.a, sc);
        auto args = new Value[e.args.length];
        foreach (k, a; e.args)
            args[k] = eval(a, sc);
        auto kwValues = new Value[e.kwArgs.length];
        foreach (k, a; e.kwArgs)
            kwValues[k] = eval(a, sc);

        switch (callee.kind)
        {
        case Kind.macroDef:
            return Value.of(callMacro(cast(MacroObj) callee.o, args, e.kwNames, kwValues));
        case Kind.rangeFn:
            return callRange(args, e.kwNames.length != 0);
        case Kind.superFn:
        {
            if (args.length || e.kwNames.length)
                throw typeError("super takes no arguments");
            auto so = cast(SuperObj) callee.o;
            auto r = cast(Rendering) so.rendering;
            auto chain = r.chains[so.name];
            if (so.index + 1 >= chain.length)
                throw undefinedError("no super block");
            auto buf = new Buf;
            executeBlock(r, so.name, so.index + 1, buf);
            return Value.of(buf.app.data.idup);
        }
        case Kind.undefined:
            throw undefinedError("calling undefined");
        default:
            throw typeError("value is not callable");
        }
    }

    private Value callRange(Value[] args, bool hasKeywords)
    {
        if (hasKeywords)
            throw typeError("range takes no keyword arguments");
        if (args.length < 1 || args.length > 3)
            throw typeError("range takes one to three arguments");
        long[3] n;
        foreach (k, a; args)
        {
            if (a.isUndefined)
                throw undefinedError("undefined range argument");
            if (a.kind != Kind.integer && a.kind != Kind.boolean)
                throw typeError("range arguments must be integers");
            n[k] = a.i;
        }
        long start = 0, stop, step = 1;
        if (args.length == 1)
            stop = n[0];
        else
        {
            start = n[0];
            stop = n[1];
            if (args.length == 3)
                step = n[2];
        }
        if (step == 0)
            throw typeError("range step must not be zero");
        Value[] items;
        if (step > 0)
            for (long x = start; x < stop; x += step)
                items ~= Value.of(x);
        else
            for (long x = start; x > stop; x += step)
                items ~= Value.of(x);
        return Value.of(items);
    }

    private string callMacro(MacroObj m, Value[] args, string[] kwNames, Value[] kwValues)
    {
        auto node = m.node;
        immutable n = node.params.length;
        if (args.length > n)
            throw typeError("too many macro arguments");
        auto ms = new Scope(m.definedIn);
        ms.names = node.params.dup;
        ms.values = new Value[n];
        auto bound = new bool[n];
        foreach (k, a; args)
        {
            ms.values[k] = a;
            bound[k] = true;
        }
        foreach (k, kw; kwNames)
        {
            size_t at = size_t.max;
            foreach (j, pn; node.params)
                if (pn == kw)
                {
                    at = j;
                    break;
                }
            if (at == size_t.max || bound[at])
                throw typeError("bad keyword argument");
            ms.values[at] = kwValues[k];
            bound[at] = true;
        }
        foreach (j; 0 .. n)
        {
            if (bound[j])
                continue;
            ms.values[j] = node.defaults[j] !is null ? eval(node.defaults[j], ms) : Value.undefined;
            bound[j] = true;
        }
        auto buf = new Buf;
        executeAll(node.body_, ms, cast(Rendering) m.rendering, buf);
        return buf.app.data.idup;
    }
}
