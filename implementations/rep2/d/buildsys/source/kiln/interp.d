/**
 * The KBL evaluator: runs a build file (and everything it includes) and
 * collects the steps, phony targets and default targets it declares.
 */
module kiln.interp;

import kiln.ast;
import kiln.builtins;
import kiln.errors;
import kiln.parser;
import kiln.paths;
import kiln.step;
import kiln.value;
import kiln.vfs;

import std.array : appender;
import std.conv : to;

/// A variable scope with a parent link.
final class Scope
{
    Scope parent;
    Value[string] vars;

    this(Scope parent = null)
    {
        this.parent = parent;
    }
}

private final class RuleDef
{
    Stmt node;
    Scope defining;
}

/// Maximum nesting of rule instantiations.
enum maxRuleDepth = 64;

/// Evaluates build files against a workspace.
final class Evaluator
{
    /// The workspace read by `include` and `glob`.
    Vfs vfs;
    /// Steps in serial order.
    Step[] steps;
    /// Phony targets in declaration order, with their dependency strings.
    string[] phonyNames;
    string[][] phonyDeps;
    int[string] phonyIndex;
    /// Default target list, in order, duplicates kept.
    string[] defaults;

    private RuleDef[string] rules;
    private string[] includeStack;
    private int ruleDepth;

    ///
    this(Vfs vfs)
    {
        this.vfs = vfs;
    }

    /// Evaluates `path` (normally `main.kiln`), which must exist.
    void run(string path)
    {
        auto root = new Scope;
        includeStack = [path];
        auto prog = parseProgram(vfs.read(path), path);
        exec(prog, root);
    }

    // ---------------------------------------------------------------- expressions

    private Value lookup(Scope sc, string name)
    {
        for (auto s = sc; s !is null; s = s.parent)
            if (auto p = name in s.vars)
                return *p;
        throw new KilnError("E_UNKNOWN_VAR", name);
    }

    private static long checkInt(const ref Value v, string site)
    {
        if (v.type != VType.int_)
            throw typeError(site, "int", typeName(v.type));
        return v.i;
    }

    /// Evaluates an expression in a scope.
    Value eval(Expr e, Scope sc)
    {
        final switch (e.kind)
        {
        case EK.intLit:
            return Value.ofInt(e.intValue);
        case EK.strLit:
            return Value.ofStr(e.text);
        case EK.boolLit:
            return Value.ofBool(e.intValue != 0);
        case EK.variable:
            return lookup(sc, e.text);
        case EK.interp:
        {
            auto app = appender!(char[]);
            foreach (ref p; e.parts)
            {
                if (p.expr is null)
                    app.put(p.literal);
                else
                {
                    auto v = eval(p.expr, sc);
                    app.put(interpolate(v));
                }
            }
            return Value.ofStr((() @trusted => cast(string) app.data)());
        }
        case EK.list:
        {
            auto items = new Value[e.kids.length];
            foreach (i, k; e.kids)
                items[i] = eval(k, sc);
            return Value.ofList(items);
        }
        case EK.neg:
        {
            auto v = eval(e.kids[0], sc);
            return Value.ofInt(-checkInt(v, "operator -"));
        }
        case EK.not:
        {
            auto v = eval(e.kids[0], sc);
            if (v.type != VType.bool_)
                throw typeError("operator !", "bool", typeName(v.type));
            return Value.ofBool(!v.b);
        }
        case EK.and:
        case EK.or:
        {
            immutable isOr = e.kind == EK.or;
            immutable site = isOr ? "operator ||" : "operator &&";
            auto l = eval(e.kids[0], sc);
            if (l.type != VType.bool_)
                throw typeError(site, "bool", typeName(l.type));
            if (l.b == isOr)
                return l;
            auto r = eval(e.kids[1], sc);
            if (r.type != VType.bool_)
                throw typeError(site, "bool", typeName(r.type));
            return r;
        }
        case EK.binary:
            return evalBinary(e, sc);
        case EK.call:
        {
            if (e.fn < 0)
                throw new KilnError("E_UNKNOWN_FUNC", e.text);
            auto args = new Value[e.kids.length];
            foreach (i, k; e.kids)
                args[i] = eval(k, sc);
            checkCall(e.fn, args);
            return callBuiltin(e.fn, args, vfs);
        }
        case EK.index:
        {
            auto x = eval(e.kids[0], sc);
            auto iv = eval(e.kids[1], sc);
            if (iv.type != VType.int_)
                throw typeError("index", "int", typeName(iv.type));
            if (x.type != VType.str && x.type != VType.list)
                throw typeError("index target", "str|list", typeName(x.type));
            immutable n = cast(long)(x.type == VType.str ? x.s.length : x.l.length);
            long k = iv.i;
            if (k < -n || k >= n)
                throw argError("fn", "index", "out of range");
            if (k < 0)
                k += n;
            if (x.type == VType.str)
                return Value.ofStr(x.s[cast(size_t) k .. cast(size_t) k + 1]);
            return x.l[cast(size_t) k];
        }
        }
    }

    private Value evalBinary(Expr e, Scope sc)
    {
        auto a = eval(e.kids[0], sc);
        auto b = eval(e.kids[1], sc);
        immutable site = "operator " ~ spelling(e.op);
        final switch (e.op)
        {
        case BinOp.add:
        case BinOp.sub:
        case BinOp.mul:
        case BinOp.div:
        case BinOp.mod:
        {
            immutable x = checkInt(a, site);
            immutable y = checkInt(b, site);
            switch (e.op)
            {
            case BinOp.add:
                return Value.ofInt(x + y);
            case BinOp.sub:
                return Value.ofInt(x - y);
            case BinOp.mul:
                return Value.ofInt(x * y);
            case BinOp.div:
                if (y == 0)
                    throw new KilnError("E_DIV_ZERO");
                return Value.ofInt(y == -1 ? -x : x / y);
            default:
                if (y == 0)
                    throw new KilnError("E_DIV_ZERO");
                return Value.ofInt(y == -1 ? 0 : x % y);
            }
        }
        case BinOp.strCat:
            if (a.type != VType.str)
                throw typeError(site, "str", typeName(a.type));
            if (b.type != VType.str)
                throw typeError(site, "str", typeName(b.type));
            return Value.ofStr(a.s ~ b.s);
        case BinOp.listCat:
            if (a.type != VType.list)
                throw typeError(site, "list", typeName(a.type));
            if (b.type != VType.list)
                throw typeError(site, "list", typeName(b.type));
            return Value.ofList(a.l ~ b.l);
        case BinOp.eq:
            return Value.ofBool(valuesEqual(a, b));
        case BinOp.ne:
            return Value.ofBool(!valuesEqual(a, b));
        case BinOp.lt:
            return Value.ofBool(compareValues(a, b) < 0);
        case BinOp.le:
            return Value.ofBool(compareValues(a, b) <= 0);
        case BinOp.gt:
            return Value.ofBool(compareValues(a, b) > 0);
        case BinOp.ge:
            return Value.ofBool(compareValues(a, b) >= 0);
        }
    }

    // ---------------------------------------------------------------- statements

    private string[] toStrList(const ref Value v, string site)
    {
        if (v.type == VType.str)
            return [v.s];
        if (v.type != VType.list)
            throw typeError(site, "strlist", typeName(v.type));
        auto r = new string[v.l.length];
        foreach (i, ref e; v.l)
        {
            if (e.type != VType.str)
                throw typeError(site, "strlist", typeName(e.type));
            r[i] = e.s;
        }
        return r;
    }

    // Shape check for `in` / `after` / phony dependency strings.
    private static void checkReference(string s)
    {
        if (s.length > 0 && s[0] == '@')
        {
            if (!isIdentifier(s[1 .. $]))
                throw new KilnError("E_BAD_PATH", s);
        }
        else if (!isWorkspacePath(s))
            throw new KilnError("E_BAD_PATH", s);
    }

    private void exec(Stmt[] block, Scope sc)
    {
        foreach (st; block)
            execOne(st, sc);
    }

    private void execOne(Stmt st, Scope sc)
    {
        final switch (st.kind)
        {
        case SK.let:
        {
            auto v = eval(st.expr, sc);
            if (st.name in sc.vars)
                throw new KilnError("E_REDEFINE", st.name);
            sc.vars[st.name] = v;
            break;
        }
        case SK.set:
        {
            auto v = eval(st.expr, sc);
            for (auto s = sc; s !is null; s = s.parent)
                if (auto p = st.name in s.vars)
                {
                    *p = v;
                    return;
                }
            throw new KilnError("E_SET_UNDEFINED", st.name);
        }
        case SK.include:
            doInclude(st, sc);
            break;
        case SK.abort:
        {
            auto v = eval(st.expr, sc);
            if (v.type != VType.str)
                throw typeError("abort message", "str", typeName(v.type));
            throw new KilnError("E_ABORT", v.s);
        }
        case SK.default_:
        {
            auto v = eval(st.expr, sc);
            defaults ~= toStrList(v, "default");
            break;
        }
        case SK.phony:
        {
            auto v = eval(st.expr, sc);
            auto deps = toStrList(v, "phony " ~ st.name);
            foreach (d; deps)
                checkReference(d);
            if (st.name in phonyIndex)
                throw new KilnError("E_DUP_PHONY", st.name);
            phonyIndex[st.name] = cast(int) phonyNames.length;
            phonyNames ~= st.name;
            phonyDeps ~= deps;
            break;
        }
        case SK.when:
        {
            foreach (i, c; st.conds)
            {
                auto v = eval(c, sc);
                if (v.type != VType.bool_)
                    throw typeError("when condition", "bool", typeName(v.type));
                if (v.b)
                {
                    exec(st.bodies[i], new Scope(sc));
                    return;
                }
            }
            if (st.bodies.length > st.conds.length)
                exec(st.bodies[$ - 1], new Scope(sc));
            break;
        }
        case SK.each:
        {
            auto subject = eval(st.expr, sc);
            if (subject.type != VType.list)
                throw typeError("each subject", "list", typeName(subject.type));
            foreach (i, ref el; subject.l)
            {
                auto inner = new Scope(sc);
                inner.vars[st.name] = el;
                if (st.indexName.length)
                    inner.vars[st.indexName] = Value.ofInt(cast(long) i);
                exec(st.block, inner);
            }
            break;
        }
        case SK.rule:
        {
            if (st.name in rules)
                throw new KilnError("E_REDEFINE", st.name);
            auto r = new RuleDef;
            r.node = st;
            r.defining = sc;
            rules[st.name] = r;
            break;
        }
        case SK.use:
            doUse(st, sc);
            break;
        case SK.step:
            doStep(st, sc);
            break;
        }
    }

    private void doInclude(Stmt st, Scope sc)
    {
        auto v = eval(st.expr, sc);
        if (v.type != VType.str)
            throw typeError("include path", "str", typeName(v.type));
        string path = v.s;
        if (!isWorkspacePath(path))
            throw new KilnError("E_BAD_PATH", path);
        if (!vfs.exists(path))
            throw new KilnError("E_INCLUDE_MISSING", path);
        foreach (p; includeStack)
            if (p == path)
                throw new KilnError("E_INCLUDE_CYCLE", path);
        auto prog = parseProgram(vfs.read(path), path);
        includeStack ~= path;
        exec(prog, sc);
        includeStack.length = includeStack.length - 1;
    }

    private void doUse(Stmt st, Scope sc)
    {
        auto rp = st.name in rules;
        if (rp is null)
            throw new KilnError("E_UNKNOWN_RULE", st.name);
        if (ruleDepth + 1 > maxRuleDepth)
            throw new KilnError("E_RULE_RECURSION", st.name);
        auto rule = *rp;
        auto values = new Value[st.args.length];
        foreach (i, a; st.args)
            values[i] = eval(a, sc);

        auto params = rule.node.params;
        auto scope_ = new Scope(rule.defining);
        bool[string] bound;
        size_t positional = 0;
        foreach (n; st.argNames)
            if (n.length == 0)
                positional++;
        if (positional > params.length)
            throw arityError("rule", st.name, params.length.to!string, positional);
        size_t pi = 0;
        foreach (i, n; st.argNames)
        {
            if (n.length != 0)
                continue;
            scope_.vars[params[pi].name] = values[i];
            bound[params[pi].name] = true;
            pi++;
        }
        foreach (i, n; st.argNames)
        {
            if (n.length == 0)
                continue;
            bool known = false;
            foreach (ref p; params)
                if (p.name == n)
                    known = true;
            if (!known)
                throw argError("rule", st.name, "unknown argument " ~ n);
            if (n in bound)
                throw argError("rule", st.name, "duplicate argument " ~ n);
            scope_.vars[n] = values[i];
            bound[n] = true;
        }
        foreach (ref p; params)
        {
            if (p.name in bound)
                continue;
            if (p.defaultValue is null)
                throw argError("rule", st.name, "missing argument " ~ p.name);
            scope_.vars[p.name] = eval(p.defaultValue, scope_);
        }
        ruleDepth++;
        exec(rule.node.block, scope_);
        ruleDepth--;
    }

    private void doStep(Stmt st, Scope sc)
    {
        auto step = new Step;
        step.serial = cast(int) steps.length;
        bool hasCost, hasDepfile, hasCmd;
        long cost;
        Cmd cmd;
        foreach (ref f; st.fields)
        {
            final switch (f.kind)
            {
            case FK.out_:
            {
                auto v = eval(f.expr, sc);
                step.outs ~= toStrList(v, "field out");
                break;
            }
            case FK.in_:
            {
                auto v = eval(f.expr, sc);
                step.ins ~= toStrList(v, "field in");
                break;
            }
            case FK.after:
            {
                auto v = eval(f.expr, sc);
                step.afters ~= toStrList(v, "field after");
                break;
            }
            case FK.cost:
            {
                if (hasCost)
                    throw new KilnError("E_STEP_FIELD", "duplicate cost");
                hasCost = true;
                auto v = eval(f.expr, sc);
                cost = checkInt(v, "field cost");
                if (cost < 0)
                    throw argError("field", "cost", "negative");
                break;
            }
            case FK.depfile:
            {
                if (hasDepfile)
                    throw new KilnError("E_STEP_FIELD", "duplicate depfile");
                hasDepfile = true;
                auto v = eval(f.expr, sc);
                if (v.type != VType.str)
                    throw typeError("field depfile", "str", typeName(v.type));
                step.depfile = v.s;
                break;
            }
            case FK.cmd:
            {
                if (hasCmd)
                    throw new KilnError("E_STEP_FIELD", "duplicate cmd");
                hasCmd = true;
                if (!findCommand(f.cmdName, cmd))
                    throw new KilnError("E_UNKNOWN_CMD", f.cmdName);
                auto args = new Value[f.cmdArgs.length];
                foreach (i, a; f.cmdArgs)
                    args[i] = eval(a, sc);
                immutable info = &cmdTable[cmd];
                if (args.length != info.sig.length)
                    throw arityError("cmd", info.name, info.sig.length.to!string, args.length);
                foreach (i, ref a; args)
                {
                    immutable want = info.sig[i] == 'S' ? VType.str : VType.int_;
                    if (a.type != want)
                        throw typeError("cmd " ~ info.name ~ " argument " ~ (i + 1).to!string,
                                typeName(want), typeName(a.type));
                }
                step.args = args;
                break;
            }
            }
        }
        validateStep(step, hasCmd, cmd, hasDepfile);
        step.cmd = cmd;
        step.cost = hasCost ? cost : cmdTable[cmd].defaultCost;
        step.canon = canonicalCommand(cmd, step.args);
        steps ~= step;
    }

    private static void validateStep(Step step, bool hasCmd, Cmd cmd, bool hasDepfile)
    {
        if (!hasCmd)
            throw new KilnError("E_STEP_FIELD", "missing cmd");
        if (step.outs.length == 0)
            throw new KilnError("E_STEP_FIELD", "missing out");
        foreach (o; step.outs)
        {
            if (!isWorkspacePath(o))
                throw new KilnError("E_BAD_PATH", o);
            if (!isGenerated(o))
                throw new KilnError("E_OUTPUT_PATH", o);
        }
        if (hasDepfile)
        {
            if (!isWorkspacePath(step.depfile))
                throw new KilnError("E_BAD_PATH", step.depfile);
            if (!isGenerated(step.depfile))
                throw new KilnError("E_OUTPUT_PATH", step.depfile);
        }
        foreach (s; step.ins)
            checkReference(s);
        foreach (s; step.afters)
            checkReference(s);
        foreach (s; step.ins)
            if (s.length == 0 || s[0] != '@')
                step.fileInputs ~= s;
        immutable info = &cmdTable[cmd];
        immutable nin = cast(int) step.fileInputs.length;
        if (nin < info.minInputs || (info.maxInputs >= 0 && nin > info.maxInputs))
        {
            immutable hi = info.maxInputs < 0 ? "N" : info.maxInputs.to!string;
            throw new KilnError("E_CMD_SHAPE", info.name ~ ": expected inputs "
                    ~ info.minInputs.to!string ~ "-" ~ hi ~ ", got " ~ nin.to!string);
        }
        if (step.outs.length != 1)
            throw new KilnError("E_CMD_SHAPE", info.name ~ ": expected outputs 1, got "
                    ~ step.outs.length.to!string);
        if (info.usesDepfile && !hasDepfile)
            throw new KilnError("E_CMD_SHAPE", info.name ~ ": depfile required");
        if (!info.usesDepfile && hasDepfile)
            throw new KilnError("E_CMD_SHAPE", info.name ~ ": depfile not allowed");
        if (cmd == Cmd.replace && step.args[0].s.length == 0)
            throw argError("cmd", "replace", "empty pattern");
        if (cmd == Cmd.indent && step.args[0].i < 0)
            throw argError("cmd", "indent", "negative");
        step.fullOutputs = step.outs.dup;
        if (hasDepfile)
            step.fullOutputs ~= step.depfile;
    }
}
