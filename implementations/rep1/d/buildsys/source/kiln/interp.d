/// The KBL evaluator: scopes, expressions, statements, rules and steps.
module kiln.interp;

import kiln.ast;
import kiln.builtins;
import kiln.bytes : decimal;
import kiln.commands;
import kiln.errors;
import kiln.parser;
import kiln.paths;
import kiln.step;
import kiln.value;
import kiln.vfs;

/// A lexical scope: a variable map with a parent link.
final class Scope
{
    Scope parent;
    Value[string] vars;

    this(Scope parent) @safe
    {
        this.parent = parent;
    }

    /// Finds the innermost binding of `name`, or null.
    Value* find(const(char)[] name) @safe
    {
        for (Scope s = this; s !is null; s = s.parent)
            if (auto p = name in s.vars)
                return p;
        return null;
    }
}

private struct RuleDef
{
    string name;
    Param[] params;
    Stmt[] body;
    Scope defScope;
}

private enum maxRuleDepth = 64;

/// Evaluates build files into a step list, phony table and default targets.
final class Interp
{
    Vfs vfs;
    Step[] steps; /// steps in serial order
    PhonyDecl[] phonies; /// phony targets in declaration order
    string[] defaults; /// accumulated default targets
    private bool[string] phonyNames;
    private RuleDef[string] rules;
    private string[] includeStack;
    private int depth;

    this(Vfs vfs) @safe
    {
        this.vfs = vfs;
    }

    /// Lexes, parses and executes `path` (normally `main.kiln`) in a fresh root scope.
    void runFile(string path) @safe
    {
        auto root = new Scope(null);
        includeStack = [path];
        auto prog = parseSource(path, vfs.content(path));
        execBlock(prog, root);
        includeStack = null;
    }

    // ------------------------------------------------------------ statements

    private void execBlock(Stmt[] stmts, Scope sc) @safe
    {
        foreach (s; stmts)
            execStmt(s, sc);
    }

    private static void expectType(const ref Value v, ubyte mask, lazy string site) @safe
    {
        if (!((1 << v.type) & mask))
            throw typeError(site, maskName(mask), v.typeName);
    }

    /// Converts a `str` or list-of-`str` value, or raises `E_TYPE` with expected `strlist`.
    private static string[] strList(const Value v, lazy string site) @safe
    {
        if (v.type == Value.Type.str)
            return [v.s];
        if (v.type != Value.Type.list)
            throw typeError(site, "strlist", v.typeName);
        string[] r;
        r.reserve(v.items.length);
        foreach (ref e; v.items)
        {
            if (e.type != Value.Type.str)
                throw typeError(site, "strlist", e.typeName);
            r ~= e.s;
        }
        return r;
    }

    private static bool validRef(string p) @safe
    {
        if (p.length && p[0] == '@')
            return isPhonyRef(p);
        return isWorkspacePath(p);
    }

    private void execStmt(Stmt s, Scope sc) @safe
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
                auto slot = sc.find(s.name);
                if (slot is null)
                    throw new KilnError("E_SET_UNDEFINED", s.name);
                *slot = v;
                break;
            }
        case StmtKind.include:
            execInclude(s, sc);
            break;
        case StmtKind.abort:
            {
                auto v = eval(s.expr, sc);
                expectType(v, tStr, "abort message");
                throw new KilnError("E_ABORT", v.s);
            }
        case StmtKind.default_:
            {
                auto v = eval(s.expr, sc);
                defaults ~= strList(v, "default");
                break;
            }
        case StmtKind.phony:
            {
                auto v = eval(s.expr, sc);
                auto deps = strList(v, "phony " ~ s.name);
                foreach (d; deps)
                    if (!validRef(d))
                        throw new KilnError("E_BAD_PATH", d);
                if (s.name in phonyNames)
                    throw new KilnError("E_DUP_PHONY", s.name);
                phonyNames[s.name] = true;
                phonies ~= PhonyDecl(s.name, deps);
                break;
            }
        case StmtKind.use:
            execUse(s, sc);
            break;
        case StmtKind.when:
            {
                foreach (i, c; s.conds)
                {
                    auto v = eval(c, sc);
                    expectType(v, tBool, "when condition");
                    if (v.isTrue)
                    {
                        execBlock(s.bodies[i], new Scope(sc));
                        return;
                    }
                }
                if (s.hasOtherwise)
                    execBlock(s.otherwise, new Scope(sc));
                break;
            }
        case StmtKind.each:
            {
                auto v = eval(s.expr, sc);
                expectType(v, tList, "each subject");
                foreach (i, ref e; v.items)
                {
                    auto inner = new Scope(sc);
                    inner.vars[s.name] = e;
                    if (s.indexName.length)
                        inner.vars[s.indexName] = Value.ofInt(cast(long) i);
                    execBlock(s.body, inner);
                }
                break;
            }
        case StmtKind.rule:
            {
                if (s.name in rules)
                    throw new KilnError("E_REDEFINE", s.name);
                rules[s.name] = RuleDef(s.name, s.params, s.body, sc);
                break;
            }
        case StmtKind.step:
            execStep(s, sc);
            break;
        }
    }

    private void execInclude(Stmt s, Scope sc) @safe
    {
        auto v = eval(s.expr, sc);
        expectType(v, tStr, "include path");
        const path = v.s;
        if (!isWorkspacePath(path))
            throw new KilnError("E_BAD_PATH", path);
        if (!vfs.exists(path))
            throw new KilnError("E_INCLUDE_MISSING", path);
        foreach (p; includeStack)
            if (p == path)
                throw new KilnError("E_INCLUDE_CYCLE", path);
        auto prog = parseSource(path, vfs.content(path));
        includeStack ~= path;
        execBlock(prog, sc);
        includeStack.length = includeStack.length - 1;
    }

    private void execUse(Stmt s, Scope sc) @safe
    {
        auto rp = s.name in rules;
        if (rp is null)
            throw new KilnError("E_UNKNOWN_RULE", s.name);
        if (depth + 1 > maxRuleDepth)
            throw new KilnError("E_RULE_RECURSION", s.name);
        auto rule = *rp;
        Value[] pos;
        pos.reserve(s.posArgs.length);
        foreach (a; s.posArgs)
            pos ~= eval(a, sc);
        Value[] kws;
        foreach (ref k; s.kwArgs)
            kws ~= eval(k.value, sc);

        auto inner = new Scope(rule.defScope);
        if (pos.length > rule.params.length)
            throw new KilnError("E_ARITY", "rule " ~ rule.name ~ ": expected " ~ decimal(
                    cast(long) rule.params.length) ~ ", got " ~ decimal(cast(long) pos.length));
        auto bound = new bool[rule.params.length];
        foreach (i, ref v; pos)
        {
            inner.vars[rule.params[i].name] = v;
            bound[i] = true;
        }
        foreach (i, ref k; s.kwArgs)
        {
            size_t idx = size_t.max;
            foreach (j, ref p; rule.params)
                if (p.name == k.name)
                {
                    idx = j;
                    break;
                }
            if (idx == size_t.max)
                throw argError("rule", rule.name, "unknown argument " ~ k.name);
            if (bound[idx])
                throw argError("rule", rule.name, "duplicate argument " ~ k.name);
            bound[idx] = true;
            inner.vars[k.name] = kws[i];
        }
        foreach (i, ref p; rule.params)
        {
            if (bound[i])
                continue;
            if (p.def is null)
                throw argError("rule", rule.name, "missing argument " ~ p.name);
            inner.vars[p.name] = eval(p.def, inner);
        }
        ++depth;
        scope (exit)
            --depth;
        execBlock(rule.body, inner);
    }

    // ----------------------------------------------------------------- steps

    private void execStep(Stmt s, Scope sc) @safe
    {
        auto st = new Step;
        bool hasCost, hasDepfile, hasCmd;
        const(CmdInfo)* info;
        st.cost = -1;
        foreach (ref f; s.fields)
        {
            final switch (f.kind)
            {
            case FieldKind.out_:
                st.outs ~= strList(eval(f.expr, sc), "field out");
                break;
            case FieldKind.in_:
                st.ins ~= strList(eval(f.expr, sc), "field in");
                break;
            case FieldKind.after:
                st.afters ~= strList(eval(f.expr, sc), "field after");
                break;
            case FieldKind.cost:
                {
                    if (hasCost)
                        throw new KilnError("E_STEP_FIELD", "duplicate cost");
                    hasCost = true;
                    auto v = eval(f.expr, sc);
                    expectType(v, tInt, "field cost");
                    if (v.num < 0)
                        throw argError("field", "cost", "negative");
                    st.cost = v.num;
                    break;
                }
            case FieldKind.depfile:
                {
                    if (hasDepfile)
                        throw new KilnError("E_STEP_FIELD", "duplicate depfile");
                    hasDepfile = true;
                    auto v = eval(f.expr, sc);
                    expectType(v, tStr, "field depfile");
                    st.depfile = v.s;
                    break;
                }
            case FieldKind.cmd:
                {
                    if (hasCmd)
                        throw new KilnError("E_STEP_FIELD", "duplicate cmd");
                    hasCmd = true;
                    info = findCommand(f.cmdName);
                    if (info is null)
                        throw new KilnError("E_UNKNOWN_CMD", f.cmdName);
                    Value[] args;
                    foreach (a; f.args)
                        args ~= eval(a, sc);
                    if (args.length != info.sig.length)
                        throw new KilnError("E_ARITY", "cmd " ~ info.name ~ ": expected " ~ decimal(
                                cast(long) info.sig.length) ~ ", got " ~ decimal(cast(long) args.length));
                    foreach (i, ref a; args)
                        expectType(a, info.sig[i] == 's' ? tStr : tInt,
                                "cmd " ~ info.name ~ " argument " ~ decimal(cast(long) i + 1));
                    st.cmd = info;
                    st.args = args;
                    break;
                }
            }
        }
        validateStep(st, hasDepfile, hasCmd);
        st.serial = cast(int) steps.length;
        if (st.cost < 0)
            st.cost = info.cost;
        st.canonical = canonicalCommand(info.name, st.args);
        st.fullOutputs = st.outs.dup;
        if (hasDepfile)
            st.fullOutputs ~= st.depfile;
        steps ~= st;
    }

    private void validateStep(Step st, bool hasDepfile, bool hasCmd) @safe
    {
        if (!hasCmd)
            throw new KilnError("E_STEP_FIELD", "missing cmd");
        if (st.outs.length == 0)
            throw new KilnError("E_STEP_FIELD", "missing out");
        void checkOut(string p)
        {
            if (!isWorkspacePath(p))
                throw new KilnError("E_BAD_PATH", p);
            if (!isOutPath(p))
                throw new KilnError("E_OUTPUT_PATH", p);
        }

        foreach (p; st.outs)
            checkOut(p);
        if (hasDepfile)
            checkOut(st.depfile);
        foreach (p; st.ins)
            if (!validRef(p))
                throw new KilnError("E_BAD_PATH", p);
        foreach (p; st.afters)
            if (!validRef(p))
                throw new KilnError("E_BAD_PATH", p);
        foreach (p; st.ins)
            if (p.length == 0 || p[0] != '@')
                st.fileInputs ~= p;
        const info = st.cmd;
        const m = cast(long) st.fileInputs.length;
        if (m < info.minIn || (info.maxIn >= 0 && m > info.maxIn))
        {
            const hi = info.maxIn < 0 ? "N" : decimal(info.maxIn);
            throw new KilnError("E_CMD_SHAPE", info.name ~ ": expected inputs " ~ decimal(
                    info.minIn) ~ "-" ~ hi ~ ", got " ~ decimal(m));
        }
        if (st.outs.length != 1)
            throw new KilnError("E_CMD_SHAPE", info.name ~ ": expected outputs 1, got " ~ decimal(
                    cast(long) st.outs.length));
        if (info.depfile && !hasDepfile)
            throw new KilnError("E_CMD_SHAPE", info.name ~ ": depfile required");
        if (!info.depfile && hasDepfile)
            throw new KilnError("E_CMD_SHAPE", info.name ~ ": depfile not allowed");
        if (info.id == CmdId.replace && st.args[0].s.length == 0)
            throw argError("cmd", "replace", "empty pattern");
        if (info.id == CmdId.indent && st.args[0].num < 0)
            throw argError("cmd", "indent", "negative");
    }

    // ----------------------------------------------------------- expressions

    /// Evaluates an expression in a scope.
    Value eval(Expr e, Scope sc) @safe
    {
        final switch (e.kind)
        {
        case ExprKind.intLit:
            return Value.ofInt(e.ival);
        case ExprKind.strLit:
            return Value.ofStr(e.name);
        case ExprKind.boolLit:
            return Value.ofBool(e.ival != 0);
        case ExprKind.interp:
            {
                char[] b;
                foreach (ref p; e.parts)
                {
                    if (p.expr is null)
                    {
                        b ~= p.text;
                        continue;
                    }
                    auto v = eval(p.expr, sc);
                    if (v.type == Value.Type.list)
                        throw new KilnError("E_INTERP", "list");
                    b ~= textOf(v);
                }
                return Value.ofStr((() @trusted => cast(string) b)());
            }
        case ExprKind.variable:
            {
                auto p = sc.find(e.name);
                if (p is null)
                    throw new KilnError("E_UNKNOWN_VAR", e.name);
                return *p;
            }
        case ExprKind.list:
            {
                Value[] items;
                items.reserve(e.kids.length);
                foreach (k; e.kids)
                    items ~= eval(k, sc);
                return Value.ofList(items);
            }
        case ExprKind.call:
            return evalCall(e, sc);
        case ExprKind.index:
            return evalIndex(e, sc);
        case ExprKind.unary:
            {
                auto v = eval(e.kids[0], sc);
                if (e.op == Op.not)
                {
                    expectType(v, tBool, "operator !");
                    return Value.ofBool(!v.isTrue);
                }
                expectType(v, tInt, "operator -");
                return Value.ofInt(-v.num);
            }
        case ExprKind.logicalAnd:
        case ExprKind.logicalOr:
            {
                const isAnd = e.kind == ExprKind.logicalAnd;
                const site = isAnd ? "operator &&" : "operator ||";
                auto l = eval(e.kids[0], sc);
                expectType(l, tBool, site);
                if (isAnd ? !l.isTrue : l.isTrue)
                    return l;
                auto r = eval(e.kids[1], sc);
                expectType(r, tBool, site);
                return r;
            }
        case ExprKind.binary:
            return evalBinary(e, sc);
        }
    }

    private Value evalBinary(Expr e, Scope sc) @safe
    {
        auto l = eval(e.kids[0], sc);
        auto r = eval(e.kids[1], sc);
        final switch (e.op)
        {
        case Op.add:
        case Op.sub:
        case Op.mul:
        case Op.div:
        case Op.mod:
            expectType(l, tInt, "operator " ~ opSpelling(e.op));
            expectType(r, tInt, "operator " ~ opSpelling(e.op));
            break;
        case Op.concatStr:
            expectType(l, tStr, "operator ~");
            expectType(r, tStr, "operator ~");
            return Value.ofStr(l.s ~ r.s);
        case Op.concatList:
            expectType(l, tList, "operator ++");
            expectType(r, tList, "operator ++");
            return Value.ofList(l.items ~ r.items);
        case Op.eq:
            return Value.ofBool(valuesEqual(l, r));
        case Op.ne:
            return Value.ofBool(!valuesEqual(l, r));
        case Op.lt:
            return Value.ofBool(compareValues(l, r) < 0);
        case Op.le:
            return Value.ofBool(compareValues(l, r) <= 0);
        case Op.gt:
            return Value.ofBool(compareValues(l, r) > 0);
        case Op.ge:
            return Value.ofBool(compareValues(l, r) >= 0);
        case Op.neg:
        case Op.not:
            assert(false);
        }
        const a = l.num, b = r.num;
        switch (e.op)
        {
        case Op.add:
            return Value.ofInt(a + b);
        case Op.sub:
            return Value.ofInt(a - b);
        case Op.mul:
            return Value.ofInt(a * b);
        case Op.div:
            if (b == 0)
                throw new KilnError("E_DIV_ZERO");
            return Value.ofInt(b == -1 ? -a : a / b);
        default:
            if (b == 0)
                throw new KilnError("E_DIV_ZERO");
            return Value.ofInt(b == -1 ? 0 : a % b);
        }
    }

    private Value evalIndex(Expr e, Scope sc) @safe
    {
        auto x = eval(e.kids[0], sc);
        auto i = eval(e.kids[1], sc);
        expectType(i, tInt, "index");
        expectType(x, tStr | tList, "index target");
        const n = cast(long)(x.type == Value.Type.str ? x.s.length : x.items.length);
        long k = i.num;
        if (k < 0)
            k += n;
        if (k < 0 || k >= n)
            throw argError("fn", "index", "out of range");
        if (x.type == Value.Type.str)
            return Value.ofStr(x.s[cast(size_t) k .. cast(size_t) k + 1]);
        return x.items[cast(size_t) k];
    }

    private Value evalCall(Expr e, Scope sc) @safe
    {
        auto fn = findBuiltin(e.name);
        if (fn is null)
            throw new KilnError("E_UNKNOWN_FUNC", e.name);
        Value[] args;
        args.reserve(e.kids.length);
        foreach (k; e.kids)
            args ~= eval(k, sc);
        const n = cast(long) args.length;
        if (n < fn.minArgs || n > fn.maxArgs)
        {
            const want = fn.minArgs == fn.maxArgs ? decimal(fn.minArgs)
                : decimal(fn.minArgs) ~ "-" ~ decimal(fn.maxArgs);
            throw new KilnError("E_ARITY", "fn " ~ fn.name ~ ": expected " ~ want ~ ", got " ~ decimal(n));
        }
        foreach (i, ref a; args)
        {
            const m = fn.masks[i < fn.masks.length ? i : fn.masks.length - 1];
            if (m != tAny && !((1 << a.type) & m))
                throw typeError("fn " ~ fn.name ~ " argument " ~ decimal(cast(long) i + 1),
                        maskName(m), a.typeName);
        }
        return fn.fn(vfs, args);
    }
}
