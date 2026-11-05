/// The KBL evaluator: scopes, expressions and statements. Evaluating a build
/// file produces a `Plan`.
module kiln.interp;

import kiln.ast;
import kiln.builtins;
import kiln.bytes;
import kiln.commands;
import kiln.errors;
import kiln.paths;
import kiln.parser : parseFile;
import kiln.plan;
import kiln.value;
import kiln.vfs;

/// A variable scope with a parent link.
final class Scope
{
    Value[string] vars;
    Scope parent;

    this(Scope parent = null)
    {
        this.parent = parent;
    }
}

private struct RuleDef
{
    Stmt stmt;
    Scope defScope;
}

/// Maximum rule instantiation depth.
enum maxRuleDepth = 64;

/// Name of the root build file.
enum rootBuildFile = "main.kiln";

/// Evaluate `main.kiln` (following includes) against `vfs`.
/// Throws `KilnError` for the first configuration error.
Plan evaluateBuild(Vfs vfs)
{
    if (!vfs.exists(rootBuildFile))
        throw new KilnError("E_NO_BUILD_FILE", rootBuildFile);
    auto it = new Interp(vfs);
    it.runFile(rootBuildFile, it.root);
    return it.plan;
}

/// The tree-walking interpreter.
final class Interp
{
    Vfs vfs;
    Plan plan;
    Scope root;
    private RuleDef[string] rules;
    private string[] includeStack;
    private int depth;

    this(Vfs vfs)
    {
        this.vfs = vfs;
        plan = new Plan;
        root = new Scope;
    }

    /// Lex, parse and run the build file at `path` in scope `sc`.
    void runFile(string path, Scope sc)
    {
        auto body = parseFile(vfs.read(path), path);
        includeStack ~= path;
        scope (exit)
            includeStack.length = includeStack.length - 1;
        execBlock(body, sc);
    }

    // ------------------------------------------------------------ statements

    private void execBlock(Stmt[] body, Scope sc)
    {
        foreach (s; body)
            exec(s, sc);
    }

    private void exec(Stmt s, Scope sc)
    {
        final switch (s.kind)
        {
        case StmtKind.let:
        {
            auto v = eval(s.expr, sc);
            if (s.name in sc.vars)
                throw new KilnError("E_REDEFINE", s.name);
            sc.vars[s.name] = v;
            break;
        }
        case StmtKind.set:
        {
            auto v = eval(s.expr, sc);
            for (auto c = sc; c !is null; c = c.parent)
                if (auto slot = s.name in c.vars)
                {
                    *slot = v;
                    return;
                }
            throw new KilnError("E_SET_UNDEFINED", s.name);
        }
        case StmtKind.include:
            execInclude(s, sc);
            break;
        case StmtKind.abort:
        {
            auto v = eval(s.expr, sc);
            if (!v.isStr)
                throw typeError("abort message", "str", typeName(v.kind));
            throw new KilnError("E_ABORT", v.s);
        }
        case StmtKind.def:
        {
            auto v = eval(s.expr, sc);
            plan.defaults ~= strList(v, "default");
            break;
        }
        case StmtKind.phony:
            execPhony(s, sc);
            break;
        case StmtKind.use:
            execUse(s, sc);
            break;
        case StmtKind.when:
        {
            foreach (ref br; s.branches)
            {
                auto c = eval(br.cond, sc);
                if (!c.isBool)
                    throw typeError("when condition", "bool", typeName(c.kind));
                if (c.num)
                {
                    execBlock(br.body, new Scope(sc));
                    return;
                }
            }
            if (s.hasOtherwise)
                execBlock(s.body, new Scope(sc));
            break;
        }
        case StmtKind.each:
        {
            auto subject = eval(s.expr, sc);
            if (!subject.isList)
                throw typeError("each subject", "list", typeName(subject.kind));
            foreach (i, ref el; subject.items)
            {
                auto inner = new Scope(sc);
                if (s.indexName.length)
                    inner.vars[s.indexName] = Value.ofInt(cast(long) i);
                inner.vars[s.name] = el;
                execBlock(s.body, inner);
            }
            break;
        }
        case StmtKind.rule:
            if (s.name in rules)
                throw new KilnError("E_REDEFINE", s.name);
            rules[s.name] = RuleDef(s, sc);
            break;
        case StmtKind.step:
            execStep(s, sc);
            break;
        }
    }

    private void execInclude(Stmt s, Scope sc)
    {
        auto v = eval(s.expr, sc);
        if (!v.isStr)
            throw typeError("include path", "str", typeName(v.kind));
        if (!isWorkspacePath(v.s))
            throw new KilnError("E_BAD_PATH", v.s);
        if (!vfs.exists(v.s))
            throw new KilnError("E_INCLUDE_MISSING", v.s);
        foreach (p; includeStack)
            if (p == v.s)
                throw new KilnError("E_INCLUDE_CYCLE", v.s);
        runFile(v.s, sc);
    }

    private void execPhony(Stmt s, Scope sc)
    {
        auto v = eval(s.expr, sc);
        auto deps = strList(v, "phony " ~ s.name);
        foreach (d; deps)
            if (!isReferenceShape(d))
                throw new KilnError("E_BAD_PATH", d);
        if (s.name in plan.phonyIndex)
            throw new KilnError("E_DUP_PHONY", s.name);
        auto ph = new PhonyDef;
        ph.name = s.name;
        ph.deps = deps;
        plan.phonyIndex[s.name] = cast(int) plan.phonies.length;
        plan.phonies ~= ph;
    }

    private void execUse(Stmt s, Scope sc)
    {
        auto rp = s.name in rules;
        if (rp is null)
            throw new KilnError("E_UNKNOWN_RULE", s.name);
        if (depth + 1 > maxRuleDepth)
            throw new KilnError("E_RULE_RECURSION", s.name);
        auto rule = *rp;
        auto params = rule.stmt.params;
        // evaluate every argument left to right in the caller's scope
        auto vals = new Value[s.args.length];
        foreach (i, ref a; s.args)
            vals[i] = eval(a.expr, sc);
        auto inner = new Scope(rule.defScope);
        bool[] bound = new bool[params.length];
        size_t positional = 0;
        foreach (i, ref a; s.args)
            if (a.name.length == 0)
                ++positional;
        if (positional > params.length)
            throw new KilnError("E_ARITY", "rule " ~ s.name ~ ": expected " ~ intText(params.length)
                    ~ ", got " ~ intText(positional));
        size_t pi = 0;
        foreach (i, ref a; s.args)
        {
            if (a.name.length)
                continue;
            inner.vars[params[pi].name] = vals[i];
            bound[pi] = true;
            ++pi;
        }
        foreach (i, ref a; s.args)
        {
            if (a.name.length == 0)
                continue;
            long found = -1;
            foreach (k, ref p; params)
                if (p.name == a.name)
                {
                    found = cast(long) k;
                    break;
                }
            if (found < 0)
                throw argError("rule", s.name, "unknown argument " ~ a.name);
            if (bound[found])
                throw argError("rule", s.name, "duplicate argument " ~ a.name);
            inner.vars[a.name] = vals[i];
            bound[found] = true;
        }
        foreach (k, ref p; params)
        {
            if (bound[k])
                continue;
            if (p.defaultExpr is null)
                throw argError("rule", s.name, "missing argument " ~ p.name);
            inner.vars[p.name] = eval(p.defaultExpr, inner);
        }
        ++depth;
        scope (exit)
            --depth;
        execBlock(rule.stmt.body, inner);
    }

    private void execStep(Stmt s, Scope sc)
    {
        auto sd = new StepDef;
        sd.serial = cast(int) plan.steps.length;
        bool hasCost, hasCmd;
        long cost = -1;
        foreach (ref f; s.fields)
        {
            final switch (f.kind)
            {
            case FieldKind.out_:
                sd.outs ~= strList(eval(f.expr, sc), "field out");
                break;
            case FieldKind.in_:
                sd.ins ~= strList(eval(f.expr, sc), "field in");
                break;
            case FieldKind.after:
                sd.afters ~= strList(eval(f.expr, sc), "field after");
                break;
            case FieldKind.cost:
            {
                if (hasCost)
                    throw new KilnError("E_STEP_FIELD", "duplicate cost");
                hasCost = true;
                auto v = eval(f.expr, sc);
                if (!v.isInt)
                    throw typeError("field cost", "int", typeName(v.kind));
                if (v.num < 0)
                    throw argError("field", "cost", "negative");
                cost = v.num;
                break;
            }
            case FieldKind.depfile:
            {
                if (sd.hasDepfile)
                    throw new KilnError("E_STEP_FIELD", "duplicate depfile");
                auto v = eval(f.expr, sc);
                if (!v.isStr)
                    throw typeError("field depfile", "str", typeName(v.kind));
                sd.depfile = v.s;
                sd.hasDepfile = true;
                break;
            }
            case FieldKind.cmd:
            {
                if (hasCmd)
                    throw new KilnError("E_STEP_FIELD", "duplicate cmd");
                hasCmd = true;
                auto spec = lookupCommand(f.cmdName);
                if (spec is null)
                    throw new KilnError("E_UNKNOWN_CMD", f.cmdName);
                auto vals = new Value[f.cmdArgs.length];
                foreach (i, e; f.cmdArgs)
                    vals[i] = eval(e, sc);
                if (vals.length != spec.argTypes.length)
                    throw new KilnError("E_ARITY", "cmd " ~ spec.name ~ ": expected "
                            ~ intText(spec.argTypes.length) ~ ", got " ~ intText(vals.length));
                foreach (i, ref v; vals)
                {
                    immutable wantInt = spec.argTypes[i] == 'i';
                    if (wantInt != v.isInt || (!wantInt && !v.isStr))
                        throw typeError("cmd " ~ spec.name ~ " argument " ~ intText(i + 1),
                                wantInt ? "int" : "str", typeName(v.kind));
                    sd.args ~= wantInt ? CmdArg.ofInt(v.num) : CmdArg.ofStr(v.s);
                }
                sd.spec = spec;
                break;
            }
            }
        }
        validateStep(sd, hasCmd, cost);
        plan.steps ~= sd;
    }

    private void validateStep(StepDef sd, bool hasCmd, long cost)
    {
        if (!hasCmd)
            throw new KilnError("E_STEP_FIELD", "missing cmd");
        if (sd.outs.length == 0)
            throw new KilnError("E_STEP_FIELD", "missing out");
        static void checkOut(string p)
        {
            if (!isWorkspacePath(p))
                throw new KilnError("E_BAD_PATH", p);
            if (!isGeneratedPath(p))
                throw new KilnError("E_OUTPUT_PATH", p);
        }
        foreach (p; sd.outs)
            checkOut(p);
        if (sd.hasDepfile)
            checkOut(sd.depfile);
        foreach (p; sd.ins)
            if (!isReferenceShape(p))
                throw new KilnError("E_BAD_PATH", p);
        foreach (p; sd.afters)
            if (!isReferenceShape(p))
                throw new KilnError("E_BAD_PATH", p);
        foreach (p; sd.ins)
            if (p.length == 0 || p[0] != '@')
                sd.fileInputs ~= p;
        auto spec = sd.spec;
        immutable m = cast(int) sd.fileInputs.length;
        if (m < spec.minIn || (spec.maxIn >= 0 && m > spec.maxIn))
        {
            string hi = spec.maxIn < 0 ? "N" : intText(spec.maxIn);
            throw new KilnError("E_CMD_SHAPE", spec.name ~ ": expected inputs " ~ intText(spec.minIn)
                    ~ "-" ~ hi ~ ", got " ~ intText(m));
        }
        if (sd.outs.length != 1)
            throw new KilnError("E_CMD_SHAPE", spec.name ~ ": expected outputs 1, got " ~ intText(sd.outs.length));
        if (spec.depfile && !sd.hasDepfile)
            throw new KilnError("E_CMD_SHAPE", spec.name ~ ": depfile required");
        if (!spec.depfile && sd.hasDepfile)
            throw new KilnError("E_CMD_SHAPE", spec.name ~ ": depfile not allowed");
        if (spec.name == "replace" && sd.args[0].s.length == 0)
            throw argError("cmd", "replace", "empty pattern");
        if (spec.name == "indent" && sd.args[0].i < 0)
            throw argError("cmd", "indent", "negative");
        sd.cost = cost >= 0 ? cost : spec.defaultCost;
        sd.canon = renderCommand(spec.name, sd.args);
    }

    // ------------------------------------------------------------ expressions

    /// Evaluate an expression in scope `sc`.
    Value eval(Expr e, Scope sc)
    {
        final switch (e.kind)
        {
        case ExprKind.intLit:
            return Value.ofInt(e.num);
        case ExprKind.boolLit:
            return Value.ofBool(e.num != 0);
        case ExprKind.strLit:
            return evalString(e, sc);
        case ExprKind.variable:
            for (auto c = sc; c !is null; c = c.parent)
                if (auto v = e.name in c.vars)
                    return *v;
            throw new KilnError("E_UNKNOWN_VAR", e.name);
        case ExprKind.list:
        {
            auto items = new Value[e.kids.length];
            foreach (i, k; e.kids)
                items[i] = eval(k, sc);
            return Value.ofList(items);
        }
        case ExprKind.unary:
        {
            auto v = eval(e.kids[0], sc);
            if (e.op == "!")
            {
                if (!v.isBool)
                    throw typeError("operator !", "bool", typeName(v.kind));
                return Value.ofBool(v.num == 0);
            }
            if (!v.isInt)
                throw typeError("operator -", "int", typeName(v.kind));
            return Value.ofInt(cast(long)(0UL - cast(ulong) v.num));
        }
        case ExprKind.binary:
            return evalBinary(e, sc);
        case ExprKind.index:
            return evalIndex(e, sc);
        case ExprKind.call:
        {
            if (e.fn < 0)
                throw new KilnError("E_UNKNOWN_FUNC", e.name);
            auto args = new Value[e.kids.length];
            foreach (i, k; e.kids)
                args[i] = eval(k, sc);
            return callBuiltin(e.fn, args, vfs);
        }
        }
    }

    private Value evalString(Expr e, Scope sc)
    {
        if (e.parts.length == 1 && e.parts[0].expr is null)
            return Value.ofStr(e.parts[0].literal);
        if (e.parts.length == 0)
            return Value.ofStr("");
        Buf b;
        foreach (ref p; e.parts)
        {
            if (p.expr is null)
                b.put(p.literal);
            else
            {
                auto v = eval(p.expr, sc);
                putInterpolated(b, v);
            }
        }
        return Value.ofStr(b.take());
    }

    private Value evalIndex(Expr e, Scope sc)
    {
        auto x = eval(e.kids[0], sc);
        auto i = eval(e.kids[1], sc);
        if (!i.isInt)
            throw typeError("index", "int", typeName(i.kind));
        if (!x.isStr && !x.isList)
            throw typeError("index target", "str|list", typeName(x.kind));
        immutable n = cast(long)(x.isStr ? x.s.length : x.items.length);
        long k = i.num;
        if (k < 0)
            k += n;
        if (k < 0 || k >= n)
            throw argError("fn", "index", "out of range");
        if (x.isStr)
            return Value.ofStr(x.s[cast(size_t) k .. cast(size_t) k + 1]);
        return x.items[cast(size_t) k];
    }

    private Value evalBinary(Expr e, Scope sc)
    {
        immutable op = e.op;
        if (op == "||" || op == "&&")
        {
            auto l = eval(e.kids[0], sc);
            if (!l.isBool)
                throw typeError("operator " ~ op, "bool", typeName(l.kind));
            if (op == "||" ? l.num != 0 : l.num == 0)
                return l;
            auto r = eval(e.kids[1], sc);
            if (!r.isBool)
                throw typeError("operator " ~ op, "bool", typeName(r.kind));
            return r;
        }
        auto l = eval(e.kids[0], sc);
        auto r = eval(e.kids[1], sc);
        switch (op)
        {
        case "==":
            return Value.ofBool(valuesEqual(l, r));
        case "!=":
            return Value.ofBool(!valuesEqual(l, r));
        case "<":
            return Value.ofBool(compareValues(l, r) < 0);
        case "<=":
            return Value.ofBool(compareValues(l, r) <= 0);
        case ">":
            return Value.ofBool(compareValues(l, r) > 0);
        case ">=":
            return Value.ofBool(compareValues(l, r) >= 0);
        case "++":
            requireKind(l, r, VKind.list, op);
            return Value.ofList(l.items ~ r.items);
        case "~":
            requireKind(l, r, VKind.str, op);
            return Value.ofStr(l.s ~ r.s);
        default:
            break;
        }
        requireKind(l, r, VKind.integer, op);
        immutable a = cast(ulong) l.num;
        immutable b = cast(ulong) r.num;
        switch (op)
        {
        case "+": return Value.ofInt(cast(long)(a + b));
        case "-": return Value.ofInt(cast(long)(a - b));
        case "*": return Value.ofInt(cast(long)(a * b));
        case "/":
            if (r.num == 0)
                throw new KilnError("E_DIV_ZERO");
            if (r.num == -1)
                return Value.ofInt(cast(long)(0UL - a));
            return Value.ofInt(l.num / r.num);
        case "%":
            if (r.num == 0)
                throw new KilnError("E_DIV_ZERO");
            if (r.num == -1)
                return Value.ofInt(0);
            return Value.ofInt(l.num % r.num);
        default:
            assert(0);
        }
    }

    private static void requireKind(const ref Value l, const ref Value r, VKind k, string op)
    {
        if (l.kind != k)
            throw typeError("operator " ~ op, typeName(k), typeName(l.kind));
        if (r.kind != k)
            throw typeError("operator " ~ op, typeName(k), typeName(r.kind));
    }
}

/// Convert a `str` or list-of-`str` value to a string array, or raise the
/// `strlist` type error for `site`.
string[] strList(const Value v, string site)
{
    if (v.isStr)
        return [v.s];
    if (v.isList)
    {
        auto r = new string[v.items.length];
        foreach (i, ref it; v.items)
        {
            if (!it.isStr)
                throw typeError(site, "strlist", typeName(it.kind));
            r[i] = it.s;
        }
        return r;
    }
    throw typeError(site, "strlist", typeName(v.kind));
}
