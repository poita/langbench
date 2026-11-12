/// Tree-walking interpreter: renders a parsed template against a context.
module jinjalite.interpreter;

import std.array : Appender, appender;
import jinjalite.ast;
import jinjalite.errors;
import jinjalite.filters;
import jinjalite.operators;
import jinjalite.scoping;
import jinjalite.value;

/// Gives the interpreter access to templates by name.
interface TemplateSource
{
    /++
        Return the parsed template called `name`, parsing and checking it on first
        use. Throws a `missingTemplate` error when there is none, and `syntax` or
        `filter` errors when it is malformed.
    +/
    Template load(string name);
}

private final class MacroClosure
{
    MacroStmt def;
    Scope definedIn;
    this(MacroStmt def, Scope definedIn) { this.def = def; this.definedIn = definedIn; }
}

/// State of one rendering of one template (the main one, or one `include`).
private final class RenderContext
{
    Scope templateScope;
    /// Per block name, the bodies from most derived to least derived.
    BlockStmt[][string] chains;
    /// The parent named by an executed `extends`, until its body runs.
    Template pendingParent;
    this(Scope templateScope) { this.templateScope = templateScope; }
}

private final class SuperRef
{
    RenderContext ctx;
    string blockName;
    size_t index;
    this(RenderContext ctx, string blockName, size_t index)
    {
        this.ctx = ctx; this.blockName = blockName; this.index = index;
    }
}

/++
    Renders templates. An interpreter is cheap to create; use one per rendering.
+/
final class Interpreter
{
    private TemplateSource loader_;
    private Appender!(char[]) out_;
    private bool suppress_;
    private RenderContext ctx_;

    ///
    this(TemplateSource loader)
    {
        loader_ = loader;
    }

    /// Render `main` with the members of `context` as the root variables.
    string render(Template main, Dict context)
    {
        out_ = appender!(char[])();
        suppress_ = false;
        auto root = new Scope(null, context);
        renderTemplate(main, new Scope(root));
        return cast(string) out_.data;
    }

    // ---- templates and blocks -------------------------------------------------------

    private void renderTemplate(Template tpl, Scope templateScope)
    {
        auto savedCtx = ctx_;
        const savedSuppress = suppress_;
        auto ctx = new RenderContext(templateScope);
        ctx_ = ctx;
        foreach (name, block; tpl.blocks)
            ctx.chains[name] = [block];

        auto current = tpl;
        while (current !is null)
        {
            suppress_ = false;
            ctx.pendingParent = null;
            execBody(current.stmts, templateScope);
            current = ctx.pendingParent;
        }
        ctx_ = savedCtx;
        suppress_ = savedSuppress;
    }

    private void renderBlock(RenderContext ctx, string name, size_t index)
    {
        auto chain = ctx.chains[name];
        auto blockScope = new Scope(ctx.templateScope);
        blockScope.set("super", Value.object(Kind.superFn, new SuperRef(ctx, name, index)));
        const savedSuppress = suppress_;
        suppress_ = false;
        execBody(chain[index].stmts, blockScope);
        suppress_ = savedSuppress;
    }

    /// Run `run` with a fresh output buffer and return what it produced.
    private string captured(void delegate() run)
    {
        auto savedOut = out_;
        const savedSuppress = suppress_;
        out_ = appender!(char[])();
        suppress_ = false;
        run();
        auto result = cast(string) out_.data;
        out_ = savedOut;
        suppress_ = savedSuppress;
        return result;
    }

    // ---- statements ---------------------------------------------------------------

    private void execBody(Stmt[] stmts, Scope sc)
    {
        foreach (stmt; stmts)
            exec(stmt, sc);
    }

    private void exec(Stmt stmt, Scope sc)
    {
        final switch (stmt.kind)
        {
        case StmtKind.text:
            if (!suppress_)
                out_.put((cast(TextStmt) stmt).text);
            break;
        case StmtKind.print:
            if (!suppress_)
                putValue(out_, eval((cast(PrintStmt) stmt).expr, sc));
            break;
        case StmtKind.if_:
        {
            auto s = cast(IfStmt) stmt;
            foreach (idx, cond; s.conds)
                if (truthy(eval(cond, sc)))
                {
                    execBody(s.bodies[idx], sc);
                    return;
                }
            execBody(s.elseBody, sc);
            break;
        }
        case StmtKind.for_:
            execFor(cast(ForStmt) stmt, sc);
            break;
        case StmtKind.set:
        {
            auto s = cast(SetStmt) stmt;
            sc.set(s.name, eval(s.value, sc));
            break;
        }
        case StmtKind.macroDef:
        {
            auto s = cast(MacroStmt) stmt;
            sc.set(s.name, Value.object(Kind.macroFn, new MacroClosure(s, sc)));
            break;
        }
        case StmtKind.include:
        {
            if (suppress_)
                break;
            auto tpl = loader_.load(templateName(eval((cast(IncludeStmt) stmt).target, sc)));
            renderTemplate(tpl, new Scope(sc));
            break;
        }
        case StmtKind.extends:
        {
            auto parent = loader_.load(templateName(eval((cast(ExtendsStmt) stmt).target, sc)));
            foreach (name, block; parent.blocks)
                ctx_.chains[name] ~= block;
            ctx_.pendingParent = parent;
            suppress_ = true;
            break;
        }
        case StmtKind.block:
            if (!suppress_)
                renderBlock(ctx_, (cast(BlockStmt) stmt).name, 0);
            break;
        }
    }

    private static string templateName(Value v)
    {
        if (v.kind == Kind.text)
            return v.s;
        requireDefined(v, "undefined template name");
        typeError("template name must be a string");
    }

    private void execFor(ForStmt s, Scope sc)
    {
        auto seq = sequenceView(eval(s.iterable, sc));
        if (seq.length == 0)
        {
            execBody(s.elseBody, sc);
            return;
        }
        const length = cast(long) seq.length;
        foreach (idx, item; seq)
        {
            auto inner = new Scope(sc);
            inner.set(s.var, item);
            inner.set("loop", Value.object(Kind.loop, new LoopInfo(cast(long) idx, length)));
            execBody(s.stmts, inner);
        }
    }

    // ---- expressions --------------------------------------------------------------

    private Value eval(Expr e, Scope sc)
    {
        final switch (e.kind)
        {
        case ExprKind.literal:
            return (cast(Literal) e).value;
        case ExprKind.name:
        {
            auto name = (cast(NameExpr) e).name;
            if (auto p = sc.lookup(name))
                return *p;
            if (name == "range")
                return Value.builtin;
            return Value.undefined;
        }
        case ExprKind.list:
        {
            auto items = (cast(ListExpr) e).items;
            auto values = new Value[items.length];
            foreach (idx, item; items)
                values[idx] = eval(item, sc);
            return Value.list(values);
        }
        case ExprKind.negate:
            return negate(eval((cast(UnaryExpr) e).operand, sc));
        case ExprKind.not:
            return Value.boolean(!truthy(eval((cast(UnaryExpr) e).operand, sc)));
        case ExprKind.binary:
        {
            auto b = cast(BinaryExpr) e;
            auto lhs = eval(b.lhs, sc);
            auto rhs = eval(b.rhs, sc);
            return binaryOp(b.op, lhs, rhs);
        }
        case ExprKind.logic:
        {
            auto l = cast(LogicExpr) e;
            auto lhs = eval(l.lhs, sc);
            if (truthy(lhs) != l.isAnd)
                return lhs;
            return eval(l.rhs, sc);
        }
        case ExprKind.compare:
        {
            auto c = cast(CompareExpr) e;
            auto left = eval(c.first, sc);
            foreach (idx, op; c.ops)
            {
                auto right = eval(c.operands[idx], sc);
                if (!compare(op, left, right))
                    return Value.boolean(false);
                left = right;
            }
            return Value.boolean(true);
        }
        case ExprKind.filter:
        {
            auto f = cast(FilterExpr) e;
            auto input = eval(f.input, sc);
            auto args = new Value[f.args.length];
            foreach (idx, arg; f.args)
                args[idx] = eval(arg, sc);
            return applyFilter(f.id, input, args);
        }
        case ExprKind.isDefined:
        {
            auto d = cast(IsDefinedExpr) e;
            return Value.boolean(!eval(d.operand, sc).isUndefined != d.negated);
        }
        case ExprKind.attribute:
        {
            auto a = cast(AttrExpr) e;
            return getItem(eval(a.object, sc), Value.text(a.name));
        }
        case ExprKind.subscript:
        {
            auto s = cast(SubscriptExpr) e;
            auto object = eval(s.object, sc);
            auto key = eval(s.key, sc);
            return getItem(object, key);
        }
        case ExprKind.call:
            return evalCall(cast(CallExpr) e, sc);
        }
    }

    private Value evalCall(CallExpr c, Scope sc)
    {
        auto callee = eval(c.callee, sc);
        auto args = new Value[c.args.length];
        foreach (idx, arg; c.args)
            args[idx] = eval(arg, sc);
        auto kwValues = new Value[c.kwValues.length];
        foreach (idx, arg; c.kwValues)
            kwValues[idx] = eval(arg, sc);

        switch (callee.kind)
        {
        case Kind.undefined:
            undefinedError("calling an undefined value");
        case Kind.macroFn:
            return callMacro(cast(MacroClosure) callee.obj, args, c.kwNames, kwValues);
        case Kind.builtin:
            return callRange(args, kwValues.length);
        case Kind.superFn:
        {
            if (args.length || kwValues.length)
                typeError("super() takes no arguments");
            auto ref_ = cast(SuperRef) callee.obj;
            auto chain = ref_.ctx.chains[ref_.blockName];
            const next = ref_.index + 1;
            if (next >= chain.length)
                undefinedError("super() has no less derived block");
            return Value.text(captured(() { renderBlock(ref_.ctx, ref_.blockName, next); }));
        }
        default:
            typeError("value is not callable");
        }
    }

    private Value callMacro(MacroClosure closure, Value[] args, string[] kwNames, Value[] kwValues)
    {
        auto def = closure.def;
        if (args.length > def.params.length)
            typeError("too many positional arguments for macro '" ~ def.name ~ "'");
        auto scope_ = new Scope(closure.definedIn);
        auto bound = new bool[def.params.length];
        foreach (idx, arg; args)
        {
            scope_.set(def.params[idx].name, arg);
            bound[idx] = true;
        }
        foreach (idx, kw; kwNames)
        {
            size_t target = size_t.max;
            foreach (p, param; def.params)
                if (param.name == kw)
                {
                    target = p;
                    break;
                }
            if (target == size_t.max)
                typeError("macro '" ~ def.name ~ "' has no parameter '" ~ kw ~ "'");
            if (bound[target])
                typeError("parameter '" ~ kw ~ "' given twice");
            scope_.set(kw, kwValues[idx]);
            bound[target] = true;
        }
        foreach (idx, param; def.params)
        {
            if (bound[idx])
                continue;
            scope_.set(param.name, param.defaultValue !is null ? eval(param.defaultValue, scope_) : Value.undefined);
        }
        return Value.text(captured(() { execBody(def.stmts, scope_); }));
    }

    private static Value callRange(Value[] args, size_t kwCount)
    {
        if (kwCount != 0)
            typeError("range() takes no keyword arguments");
        if (args.length < 1 || args.length > 3)
            typeError("range() takes one to three arguments");
        foreach (arg; args)
        {
            requireDefined(arg, "undefined argument to range()");
            if (!arg.isIntegral)
                typeError("range() arguments must be integers");
        }
        long start = 0, stop, step = 1;
        if (args.length == 1)
            stop = args[0].i;
        else
        {
            start = args[0].i;
            stop = args[1].i;
            if (args.length == 3)
                step = args[2].i;
        }
        if (step == 0)
            typeError("range() step must not be zero");
        Value[] items;
        if (step > 0 && start < stop)
        {
            items.reserve(cast(size_t)((stop - start + step - 1) / step));
            for (long v = start; v < stop; v += step)
                items ~= Value.integer(v);
        }
        else if (step < 0 && start > stop)
        {
            items.reserve(cast(size_t)((start - stop - step - 1) / -step));
            for (long v = start; v > stop; v += step)
                items ~= Value.integer(v);
        }
        return Value.list(items);
    }
}
