/// Tree-walking interpreter: evaluates expressions and executes statements
/// of loaded templates, appending to a single output buffer.
module jtemplate.interp;

import jtemplate.ast;
import jtemplate.buffer;
import jtemplate.errors;
import jtemplate.filters;
import jtemplate.format;
import jtemplate.ops;
import jtemplate.scopes;
import jtemplate.value;

/// Something that can supply loaded (parsed and checked) templates by name.
interface TemplateLoader
{
    /// Return the template called `name`, loading it on first use. Throws a
    /// `template` error if there is none, `syntax` / `filter` errors if it is
    /// malformed.
    Template load(string name);
}

/// Renders templates. One interpreter serves one render call.
final class Interpreter
{
    private enum maxCallDepth = 1000;
    private enum maxIncludeDepth = 200;

    private TemplateLoader loader_;
    private uint callDepth_;
    private uint includeDepth_;

    ///
    this(TemplateLoader loader)
    {
        loader_ = loader;
    }

    /// Render template `mainName` with the members of `context` as the root
    /// variables, and return the output.
    string render(string mainName, DictObj context)
    {
        auto main = loader_.load(mainName);
        auto root = Scope.makeRoot(context);
        OutBuf out_;
        renderTemplate(main, root, out_);
        return out_.take();
    }

    // ---- templates ---------------------------------------------------------

    /// Render `t` in a new template scope under `parent`, appending to `out_`.
    /// Follows `extends` chains: each parent body runs in the same scope.
    private void renderTemplate(Template t, Scope parent, ref OutBuf out_)
    {
        if (++includeDepth_ > maxIncludeDepth)
            throw typeError("templates nested too deeply");
        scope (exit) --includeDepth_;

        auto r = new Rendering(new Scope(parent));
        r.addBlocks(t);
        Template cur = t;
        uint hops = 0;
        while (cur !is null)
        {
            if (++hops > maxIncludeDepth)
                throw typeError("template inheritance too deep");
            r.pendingParent = null;
            bool skipping = false;
            foreach (n; cur.body)
            {
                if (skipping)
                {
                    // After `extends` only definitions take effect.
                    if (n.kind == NodeKind.set || n.kind == NodeKind.macro_)
                        execNode(n, r.templateScope, r, out_);
                    continue;
                }
                execNode(n, r.templateScope, r, out_);
                if (n.kind == NodeKind.extends)
                    skipping = true;
            }
            cur = r.pendingParent;
        }
    }

    private string templateName(Value v)
    {
        if (v.kind == Kind.str) return v.s;
        if (v.isUndefined) throw undefinedError("template name is undefined");
        throw typeError("template name must be a string");
    }

    // ---- statements --------------------------------------------------------

    private void execList(Node[] nodes, Scope sc, Rendering r, ref OutBuf out_)
    {
        foreach (n; nodes)
            execNode(n, sc, r, out_);
    }

    private void execNode(Node n, Scope sc, Rendering r, ref OutBuf out_)
    {
        final switch (n.kind)
        {
            case NodeKind.text:
                out_.put(as!TextNode(n).text);
                break;
            case NodeKind.print:
                putValue(out_, eval(as!PrintNode(n).expr, sc));
                break;
            case NodeKind.if_:
            {
                auto node = as!IfNode(n);
                foreach (i, cond; node.conds)
                {
                    if (truthy(eval(cond, sc)))
                    {
                        execList(node.bodies[i], sc, r, out_);
                        return;
                    }
                }
                execList(node.elseBody, sc, r, out_);
                break;
            }
            case NodeKind.for_:
                execFor(as!ForNode(n), sc, r, out_);
                break;
            case NodeKind.set:
            {
                auto node = as!SetNode(n);
                sc.bind(node.name, eval(node.expr, sc));
                break;
            }
            case NodeKind.macro_:
            {
                auto node = as!MacroNode(n);
                Value v;
                v.kind = Kind.macro_;
                v.mac = new MacroObj(node, sc, r);
                sc.bind(node.name, v);
                break;
            }
            case NodeKind.include:
            {
                auto name = templateName(eval(as!IncludeNode(n).expr, sc));
                renderTemplate(loader_.load(name), sc, out_);
                break;
            }
            case NodeKind.extends:
            {
                auto name = templateName(eval(as!ExtendsNode(n).expr, sc));
                auto parent = loader_.load(name);
                r.addBlocks(parent);
                r.pendingParent = parent;
                break;
            }
            case NodeKind.block:
            {
                auto node = as!BlockNode(n);
                if (auto chain = node.name in r.chains)
                    renderBlock(r, node.name, *chain, 0, out_);
                else
                    renderBlock(r, node.name, [node], 0, out_);
                break;
            }
        }
    }

    private void execFor(ForNode f, Scope sc, Rendering r, ref OutBuf out_)
    {
        auto items = sequenceView(eval(f.iterable, sc));
        if (items.length == 0)
        {
            execList(f.elseBody, sc, r, out_);
            return;
        }
        // One scope serves every iteration: nothing in a loop body can keep
        // a reference to it past the iteration.
        auto ls = new Scope(sc, 4);
        immutable n = items.length;
        foreach (k; 0 .. n)
        {
            ls.reset();
            ls.bindNew(f.var, items[k]);
            ls.bindNew("loop", Value.fromLoop(k, n));
            execList(f.body, ls, r, out_);
        }
    }

    /// Render entry `k` of a block's chain in a fresh block scope.
    private void renderBlock(Rendering r, string name, BlockNode[] chain, size_t k, ref OutBuf out_)
    {
        auto bs = new Scope(r.templateScope, 2);
        Value sup;
        sup.kind = Kind.superFn;
        sup.sup = new SuperObj(r, name, k);
        bs.bindNew("super", sup);
        execList(chain[k].body, bs, r, out_);
    }

    private Value callSuper(SuperObj s)
    {
        auto chain = s.rendering.chains[s.blockName];
        immutable k = s.index + 1;
        if (k >= chain.length)
            throw undefinedError("no less derived block for super()");
        OutBuf buf;
        renderBlock(s.rendering, s.blockName, chain, k, buf);
        return Value.fromString(buf.take());
    }

    // ---- expressions -------------------------------------------------------

    /// Evaluate an expression in scope `sc`.
    Value eval(Expr e, Scope sc)
    {
        final switch (e.kind)
        {
            case ExprKind.literal:
                return as!LiteralExpr(e).value;
            case ExprKind.name:
            {
                auto n = as!NameExpr(e);
                auto v = sc.lookup(n.name);
                if (v.kind == Kind.undefined && n.isRange)
                    v.kind = Kind.rangeFn;
                return v;
            }
            case ExprKind.attr:
            {
                auto a = as!AttrExpr(e);
                return getItem(eval(a.obj, sc), a.key);
            }
            case ExprKind.index:
            {
                auto a = as!IndexExpr(e);
                auto obj = eval(a.obj, sc);
                auto key = eval(a.index, sc);
                return getItem(obj, key);
            }
            case ExprKind.call:
                return evalCall(as!CallExpr(e), sc);
            case ExprKind.neg:
                return negate(eval(as!UnaryExpr(e).operand, sc));
            case ExprKind.not:
                return Value.fromBool(!truthy(eval(as!UnaryExpr(e).operand, sc)));
            case ExprKind.binary:
            {
                auto b = as!BinaryExpr(e);
                auto l = eval(b.lhs, sc);
                auto r = eval(b.rhs, sc);
                return binaryOp(b.op, l, r);
            }
            case ExprKind.compare:
            {
                auto c = as!CompareExpr(e);
                auto left = eval(c.first, sc);
                foreach (i, op; c.ops)
                {
                    auto right = eval(c.rest[i], sc);
                    if (!compareOp(op, left, right))
                        return Value.fromBool(false);
                    left = right;
                }
                return Value.fromBool(true);
            }
            case ExprKind.and:
            {
                auto l = as!LogicExpr(e);
                auto left = eval(l.lhs, sc);
                return truthy(left) ? eval(l.rhs, sc) : left;
            }
            case ExprKind.or:
            {
                auto l = as!LogicExpr(e);
                auto left = eval(l.lhs, sc);
                return truthy(left) ? left : eval(l.rhs, sc);
            }
            case ExprKind.filter:
            {
                auto f = as!FilterExpr(e);
                auto input = eval(f.input, sc);
                immutable na = f.args.length;
                Value[4] small = void;
                Value[] args = na <= small.length ? small[0 .. na] : new Value[na];
                foreach (i, a; f.args)
                    args[i] = eval(a, sc);
                return applyFilter(f.id, input, args);
            }
            case ExprKind.defined:
            {
                auto d = as!DefinedExpr(e);
                auto v = eval(d.input, sc);
                return Value.fromBool(v.isUndefined == d.negate);
            }
            case ExprKind.list:
            {
                auto l = as!ListExpr(e);
                auto items = new Value[l.items.length];
                foreach (i, it; l.items)
                    items[i] = eval(it, sc);
                return Value.fromList(items);
            }
        }
    }

    private Value evalCall(CallExpr c, Scope sc)
    {
        auto callee = eval(c.callee, sc);
        immutable na = c.args.length, nk = c.kwNames.length;
        Value[6] small = void;
        Value[] vals = na + nk <= small.length ? small[0 .. na + nk] : new Value[na + nk];
        foreach (i, a; c.args)
            vals[i] = eval(a, sc);
        foreach (i, a; c.kwValues)
            vals[na + i] = eval(a, sc);

        switch (callee.kind)
        {
            case Kind.macro_:
                return callMacro(callee.mac, vals[0 .. na], c.kwNames, vals[na .. $]);
            case Kind.rangeFn:
                return callRange(vals[0 .. na], nk);
            case Kind.superFn:
                if (na + nk != 0)
                    throw typeError("super() takes no arguments");
                return callSuper(callee.sup);
            case Kind.undefined:
                throw undefinedError("calling an undefined value");
            default:
                throw typeError("value is not callable");
        }
    }

    private Value callMacro(MacroObj m, Value[] args, string[] kwNames, Value[] kwVals)
    {
        auto node = m.node;
        immutable np = node.params.length;
        if (args.length > np)
            throw typeError("too many arguments for macro");
        if (++callDepth_ > maxCallDepth)
            throw typeError("macro recursion too deep");
        scope (exit) --callDepth_;

        auto ms = new Scope(m.scope_, np);
        foreach (j; 0 .. np)
            ms.bindNew(node.params[j], j < args.length ? args[j] : unsetValue);
        foreach (i, kw; kwNames)
        {
            size_t j = 0;
            while (j < np && node.params[j] != kw) ++j;
            if (j == np)
                throw typeError("unknown keyword argument");
            if (ms.slot(j).kind != Kind.unset)
                throw typeError("argument given twice");
            ms.setSlot(j, kwVals[i]);
        }
        foreach (j; args.length .. np)
        {
            if (ms.slot(j).kind != Kind.unset)
                continue;
            auto def = node.defaults[j];
            ms.setSlot(j, def !is null ? eval(def, ms) : Value.undef);
        }

        OutBuf buf;
        execList(node.body, ms, m.rendering, buf);
        return Value.fromString(buf.take());
    }

    private static @property Value unsetValue()
    {
        Value v;
        v.kind = Kind.unset;
        return v;
    }

    private Value callRange(Value[] args, size_t keywordCount)
    {
        if (keywordCount != 0)
            throw typeError("range() takes no keyword arguments");
        if (args.length == 0 || args.length > 3)
            throw typeError("range() takes 1 to 3 arguments");
        long[3] a;
        foreach (i, ref v; args)
        {
            if (v.isUndefined) throw undefinedError("range() argument is undefined");
            if (!v.isIntegral) throw typeError("range() arguments must be integers");
            a[i] = v.i;
        }
        long start = 0, stop, step = 1;
        if (args.length == 1) stop = a[0];
        else { start = a[0]; stop = a[1]; if (args.length == 3) step = a[2]; }
        if (step == 0)
            throw typeError("range() step must not be zero");

        long count = 0;
        if (step > 0 && stop > start)
            count = (stop - start + step - 1) / step;
        else if (step < 0 && start > stop)
            count = (start - stop + (-step) - 1) / (-step);
        auto items = new Value[cast(size_t) count];
        long cur = start;
        foreach (ref slot; items)
        {
            slot = Value.fromInt(cur);
            cur += step;
        }
        return Value.fromList(items);
    }
}
