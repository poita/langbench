/**
 * The KBL interpreter: a tree-walking evaluator over a chain of lexical
 * scopes that turns a build file into a $(LREF BuildPlan).
 */
module kiln.eval;

import kiln.ast;
import kiln.builtins;
import kiln.bytes : decimal;
import kiln.commands;
import kiln.errors;
import kiln.lexer : isIdentShaped;
import kiln.model;
import kiln.parser : parseBuildFile;
import kiln.value;
import kiln.workspace : Workspace, isGeneratedPath, isWorkspacePath;

/// The root build file.
enum mainBuildFile = "main.kiln";

/// Maximum rule instantiation depth.
enum maxRuleDepth = 64;

/// A lexical scope: a mutable name→value map with a parent pointer.
final class Scope
{
    Scope parent;
    Value[string] vars;

    this(Scope parent) @safe pure nothrow @nogc
    {
        this.parent = parent;
    }

    /// The binding of `name` in this scope or an ancestor, or null.
    Value* lookup(const(char)[] name) @safe pure nothrow
    {
        for (auto s = this; s !is null; s = s.parent)
            if (auto p = name in s.vars)
                return p;
        return null;
    }
}

private final class Rule
{
    string name;
    Param[] params;
    Stmt[] children;
    Scope definedIn; // kept by reference, not copied
}

/// Accumulates one `step` block's fields.
private struct StepDraft
{
    string[] outs, ins, afters;
    bool hasCost, hasDepfile, hasCmd;
    long cost;
    string depfile;
    string cmdName;
    Value[] cmdArgs;
}

/// Evaluates build files against a workspace.
final class Interpreter
{
    private Workspace ws;
    private BuildPlan plan;
    private Rule[string] rules;
    private string[] includeStack;
    private int ruleDepth;

    ///
    this(Workspace ws) @safe pure nothrow @nogc
    {
        this.ws = ws;
    }

    /**
     * Lexes, parses and executes `main.kiln` (which must exist) and everything
     * it includes. Throws `KilnError` for the first error encountered.
     */
    BuildPlan evaluate() @safe
    {
        plan = new BuildPlan;
        rules = null;
        includeStack = [mainBuildFile];
        ruleDepth = 0;
        auto root = new Scope(null);
        auto stmts = parseBuildFile(ws.read(mainBuildFile), mainBuildFile);
        execBlock(stmts, root);
        return plan;
    }

    // ---- statements -------------------------------------------------------

    private void execBlock(Stmt[] stmts, Scope sc) @safe
    {
        foreach (st; stmts)
            exec(st, sc);
    }

    private void exec(Stmt st, Scope sc) @safe
    {
        final switch (st.kind)
        {
        case StmtKind.let:
            {
                auto v = eval(st.expr, sc);
                if (st.name in sc.vars)
                    fail("E_REDEFINE", st.name);
                sc.vars[st.name] = v;
                break;
            }
        case StmtKind.set:
            {
                auto v = eval(st.expr, sc);
                auto p = sc.lookup(st.name);
                if (p is null)
                    fail("E_SET_UNDEFINED", st.name);
                *p = v;
                break;
            }
        case StmtKind.include:
            execInclude(st, sc);
            break;
        case StmtKind.abort:
            {
                auto v = eval(st.expr, sc);
                expectType(v, ValueType.str, "abort message");
                fail("E_ABORT", v.s);
            }
        case StmtKind.defaultTargets:
            {
                auto v = eval(st.expr, sc);
                plan.defaults ~= toStrings(v, "default");
                break;
            }
        case StmtKind.phony:
            execPhony(st, sc);
            break;
        case StmtKind.use:
            execUse(st, sc);
            break;
        case StmtKind.when:
            {
                foreach (k, cond; st.conds)
                {
                    auto c = eval(cond, sc);
                    expectType(c, ValueType.boolean, "when condition");
                    if (c.asBool)
                    {
                        execBlock(st.branches[k], new Scope(sc));
                        return;
                    }
                }
                if (st.hasOtherwise)
                    execBlock(st.otherwise, new Scope(sc));
                break;
            }
        case StmtKind.each:
            {
                auto subject = eval(st.expr, sc);
                expectType(subject, ValueType.list, "each subject");
                foreach (k, ref e; subject.l)
                {
                    auto inner = new Scope(sc);
                    inner.vars[st.name] = e;
                    if (st.indexName.length)
                        inner.vars[st.indexName] = Value.ofInt(cast(long) k);
                    execBlock(st.children, inner);
                }
                break;
            }
        case StmtKind.rule:
            {
                if (st.name in rules)
                    fail("E_REDEFINE", st.name);
                auto r = new Rule;
                r.name = st.name;
                r.params = st.params;
                r.children = st.children;
                r.definedIn = sc;
                rules[st.name] = r;
                break;
            }
        case StmtKind.step:
            execStep(st, sc);
            break;
        case StmtKind.fieldOut:
        case StmtKind.fieldIn:
        case StmtKind.fieldAfter:
        case StmtKind.fieldCost:
        case StmtKind.fieldDepfile:
        case StmtKind.fieldCmd:
            assert(0, "step field outside a step");
        }
    }

    private void execInclude(Stmt st, Scope sc) @safe
    {
        auto v = eval(st.expr, sc);
        expectType(v, ValueType.str, "include path");
        if (!isWorkspacePath(v.s))
            fail("E_BAD_PATH", v.s);
        if (!ws.exists(v.s))
            fail("E_INCLUDE_MISSING", v.s);
        foreach (p; includeStack)
            if (p == v.s)
                fail("E_INCLUDE_CYCLE", v.s);
        auto stmts = parseBuildFile(ws.read(v.s), v.s);
        includeStack ~= v.s;
        execBlock(stmts, sc);
        includeStack = includeStack[0 .. $ - 1];
    }

    private void execPhony(Stmt st, Scope sc) @safe
    {
        auto v = eval(st.expr, sc);
        auto deps = toStrings(v, "phony " ~ st.name);
        foreach (d; deps)
            checkReferenceShape(d);
        if (st.name in plan.phonyIndex)
            fail("E_DUP_PHONY", st.name);
        plan.phonyIndex[st.name] = plan.phonies.length;
        plan.phonies ~= Phony(st.name, deps);
    }

    private void execUse(Stmt st, Scope sc) @safe
    {
        auto rp = st.name in rules;
        if (rp is null)
            fail("E_UNKNOWN_RULE", st.name);
        auto rule = *rp;
        if (ruleDepth + 1 > maxRuleDepth)
            fail("E_RULE_RECURSION", st.name);

        Value[] positional;
        Value[] keywordValues;
        string[] keywords;
        foreach (ref a; st.useArgs)
        {
            auto v = eval(a.value, sc);
            if (a.keyword.length == 0)
            {
                positional ~= v;
            }
            else
            {
                keywords ~= a.keyword;
                keywordValues ~= v;
            }
        }

        auto inner = new Scope(rule.definedIn);
        if (positional.length > rule.params.length)
            fail("E_ARITY", "rule " ~ rule.name ~ ": expected " ~ decimal(rule.params.length)
                    ~ ", got " ~ decimal(positional.length));
        foreach (k, ref v; positional)
            inner.vars[rule.params[k].name] = v;
        foreach (k, kw; keywords)
        {
            bool known = false;
            foreach (ref p; rule.params)
                if (p.name == kw)
                    known = true;
            if (!known)
                fail("E_ARG", "rule " ~ rule.name ~ ": unknown argument " ~ kw);
            if (kw in inner.vars)
                fail("E_ARG", "rule " ~ rule.name ~ ": duplicate argument " ~ kw);
            inner.vars[kw] = keywordValues[k];
        }
        foreach (ref p; rule.params)
        {
            if (p.name in inner.vars)
                continue;
            if (p.defaultValue is null)
                fail("E_ARG", "rule " ~ rule.name ~ ": missing argument " ~ p.name);
            inner.vars[p.name] = eval(p.defaultValue, inner);
        }
        ruleDepth++;
        scope (exit)
            ruleDepth--;
        execBlock(rule.children, inner);
    }

    // ---- steps ---------------------------------------------------------------

    private void execStep(Stmt st, Scope sc) @safe
    {
        StepDraft d;
        foreach (f; st.fields)
        {
            final switch (f.kind)
            {
            case StmtKind.fieldOut:
                d.outs ~= toStrings(eval(f.expr, sc), "field out");
                break;
            case StmtKind.fieldIn:
                d.ins ~= toStrings(eval(f.expr, sc), "field in");
                break;
            case StmtKind.fieldAfter:
                d.afters ~= toStrings(eval(f.expr, sc), "field after");
                break;
            case StmtKind.fieldCost:
                {
                    if (d.hasCost)
                        fail("E_STEP_FIELD", "duplicate cost");
                    d.hasCost = true;
                    auto v = eval(f.expr, sc);
                    expectType(v, ValueType.integer, "field cost");
                    if (v.i < 0)
                        fail("E_ARG", "field cost: negative");
                    d.cost = v.i;
                    break;
                }
            case StmtKind.fieldDepfile:
                {
                    if (d.hasDepfile)
                        fail("E_STEP_FIELD", "duplicate depfile");
                    d.hasDepfile = true;
                    auto v = eval(f.expr, sc);
                    expectType(v, ValueType.str, "field depfile");
                    d.depfile = v.s;
                    break;
                }
            case StmtKind.fieldCmd:
                evalCmdField(f, sc, d);
                break;
            case StmtKind.let:
            case StmtKind.set:
            case StmtKind.include:
            case StmtKind.abort:
            case StmtKind.defaultTargets:
            case StmtKind.phony:
            case StmtKind.use:
            case StmtKind.when:
            case StmtKind.each:
            case StmtKind.rule:
            case StmtKind.step:
                assert(0, "not a step field");
            }
        }
        plan.steps ~= finishStep(d, cast(int) plan.steps.length);
    }

    private void evalCmdField(Stmt f, Scope sc, ref StepDraft d) @safe
    {
        if (d.hasCmd)
            fail("E_STEP_FIELD", "duplicate cmd");
        d.hasCmd = true;
        auto spec = lookupCommand(f.name);
        if (spec is null)
            fail("E_UNKNOWN_CMD", f.name);
        Value[] args;
        foreach (e; f.cmdArgs)
            args ~= eval(e, sc);
        if (args.length != spec.args.length)
            fail("E_ARITY", "cmd " ~ f.name ~ ": expected " ~ decimal(spec.args.length) ~ ", got "
                    ~ decimal(args.length));
        foreach (k, ref a; args)
        {
            immutable want = spec.args[k] == ArgKind.str ? ValueType.str : ValueType.integer;
            if (a.type != want)
                failType("cmd " ~ f.name ~ " argument " ~ decimal(k + 1), typeName(want), typeName(a));
        }
        d.cmdName = f.name;
        d.cmdArgs = args;
    }

    /// Closing-brace validation of a step, in the order the spec fixes.
    private Step finishStep(ref StepDraft d, int serial) @safe
    {
        if (!d.hasCmd)
            fail("E_STEP_FIELD", "missing cmd");
        if (d.outs.length == 0)
            fail("E_STEP_FIELD", "missing out");
        foreach (o; d.outs)
            checkOutputPath(o);
        if (d.hasDepfile)
            checkOutputPath(d.depfile);
        foreach (i; d.ins)
            checkReferenceShape(i);
        foreach (a; d.afters)
            checkReferenceShape(a);

        auto spec = lookupCommand(d.cmdName);
        string[] fileInputs;
        foreach (i; d.ins)
            if (i.length == 0 || i[0] != '@')
                fileInputs ~= i;
        if (fileInputs.length < spec.minInputs || fileInputs.length > spec.maxInputs)
            fail("E_CMD_SHAPE", spec.name ~ ": expected inputs " ~ inputRange(*spec) ~ ", got "
                    ~ decimal(fileInputs.length));
        if (d.outs.length != 1)
            fail("E_CMD_SHAPE", spec.name ~ ": expected outputs 1, got " ~ decimal(d.outs.length));
        if (spec.usesDepfile && !d.hasDepfile)
            fail("E_CMD_SHAPE", spec.name ~ ": depfile required");
        if (!spec.usesDepfile && d.hasDepfile)
            fail("E_CMD_SHAPE", spec.name ~ ": depfile not allowed");
        if (spec.name == "replace" && d.cmdArgs[0].s.length == 0)
            fail("E_ARG", "cmd replace: empty pattern");
        if (spec.name == "indent" && d.cmdArgs[0].i < 0)
            fail("E_ARG", "cmd indent: negative");

        auto s = new Step;
        s.serial = serial;
        s.outs = d.outs;
        s.ins = d.ins;
        s.afters = d.afters;
        s.cmdName = d.cmdName;
        s.cmdArgs = d.cmdArgs;
        s.hasCost = d.hasCost;
        s.cost = d.cost;
        s.hasDepfile = d.hasDepfile;
        s.depfile = d.depfile;
        s.fullOuts = d.hasDepfile ? d.outs ~ d.depfile : d.outs;
        s.fileInputs = fileInputs;
        s.cmdString = renderCommand(d.cmdName, d.cmdArgs);
        s.effectiveCost = d.hasCost ? d.cost : spec.defaultCost;
        return s;
    }

    // ---- expressions ----------------------------------------------------------

    /// Evaluates an expression in `sc`.
    Value eval(Expr e, Scope sc) @safe
    {
        final switch (e.kind)
        {
        case ExprKind.literal:
            return e.lit;
        case ExprKind.interpolated:
            return evalInterpolated(e, sc);
        case ExprKind.variable:
            {
                auto p = sc.lookup(e.name);
                if (p is null)
                    fail("E_UNKNOWN_VAR", e.name);
                return *p;
            }
        case ExprKind.list:
            {
                auto items = new Value[e.args.length];
                foreach (k, a; e.args)
                    items[k] = eval(a, sc);
                return Value.ofList(items);
            }
        case ExprKind.unary:
            {
                auto v = eval(e.lhs, sc);
                if (e.unop == UnOp.not)
                {
                    expectType(v, ValueType.boolean, "operator !");
                    return Value.ofBool(!v.asBool);
                }
                expectType(v, ValueType.integer, "operator -");
                return Value.ofInt(-v.i);
            }
        case ExprKind.binary:
            return evalBinary(e, sc);
        case ExprKind.call:
            {
                auto fn = lookupBuiltin(e.name);
                if (fn is null)
                    fail("E_UNKNOWN_FUNC", e.name);
                auto args = new Value[e.args.length];
                foreach (k, a; e.args)
                    args[k] = eval(a, sc);
                return callBuiltin(fn, args, ws);
            }
        case ExprKind.index:
            return evalIndex(e, sc);
        }
    }

    private Value evalInterpolated(Expr e, Scope sc) @safe
    {
        char[] buf;
        foreach (ref p; e.parts)
        {
            if (p.expr is null)
            {
                buf ~= p.text;
                continue;
            }
            auto v = eval(p.expr, sc);
            if (v.type == ValueType.list)
                fail("E_INTERP", "list");
            buf ~= scalarText(v);
        }
        return Value.ofStr((() @trusted => cast(string) buf)());
    }

    private Value evalBinary(Expr e, Scope sc) @safe
    {
        immutable op = e.binop;
        if (op == BinOp.or || op == BinOp.and)
        {
            auto l = eval(e.lhs, sc);
            expectType(l, ValueType.boolean, "operator " ~ spelling(op));
            if (op == BinOp.or ? l.asBool : !l.asBool)
                return l;
            auto r = eval(e.rhs, sc);
            expectType(r, ValueType.boolean, "operator " ~ spelling(op));
            return r;
        }
        auto l = eval(e.lhs, sc);
        auto r = eval(e.rhs, sc);
        final switch (op)
        {
        case BinOp.or:
        case BinOp.and:
            assert(0);
        case BinOp.eq:
            return Value.ofBool(valuesEqual(l, r));
        case BinOp.ne:
            return Value.ofBool(!valuesEqual(l, r));
        case BinOp.lt:
            return Value.ofBool(compareValues(l, r) < 0);
        case BinOp.le:
            return Value.ofBool(compareValues(l, r) <= 0);
        case BinOp.gt:
            return Value.ofBool(compareValues(l, r) > 0);
        case BinOp.ge:
            return Value.ofBool(compareValues(l, r) >= 0);
        case BinOp.listCat:
            expectOperands(l, r, ValueType.list, op);
            return Value.ofList(l.l ~ r.l);
        case BinOp.strCat:
            expectOperands(l, r, ValueType.str, op);
            return Value.ofStr(l.s ~ r.s);
        case BinOp.add:
            expectOperands(l, r, ValueType.integer, op);
            return Value.ofInt(l.i + r.i);
        case BinOp.sub:
            expectOperands(l, r, ValueType.integer, op);
            return Value.ofInt(l.i - r.i);
        case BinOp.mul:
            expectOperands(l, r, ValueType.integer, op);
            return Value.ofInt(l.i * r.i);
        case BinOp.div:
            expectOperands(l, r, ValueType.integer, op);
            if (r.i == 0)
                failBare("E_DIV_ZERO");
            return Value.ofInt(r.i == -1 ? -l.i : l.i / r.i);
        case BinOp.mod:
            expectOperands(l, r, ValueType.integer, op);
            if (r.i == 0)
                failBare("E_DIV_ZERO");
            return Value.ofInt(r.i == -1 ? 0 : l.i % r.i);
        }
    }

    private static void expectOperands(ref Value l, ref Value r, ValueType t, BinOp op) @safe pure
    {
        expectType(l, t, "operator " ~ spelling(op));
        expectType(r, t, "operator " ~ spelling(op));
    }

    private Value evalIndex(Expr e, Scope sc) @safe
    {
        auto target = eval(e.lhs, sc);
        auto idx = eval(e.rhs, sc);
        expectType(idx, ValueType.integer, "index");
        if (target.type != ValueType.str && target.type != ValueType.list)
            failType("index target", "str|list", typeName(target));
        immutable n = cast(long)(target.type == ValueType.str ? target.s.length : target.l.length);
        long i = idx.i;
        if (i < 0)
            i += n;
        if (idx.i < -n || idx.i >= n)
            fail("E_ARG", "fn index: out of range");
        if (target.type == ValueType.str)
            return Value.ofStr(target.s[cast(size_t) i .. cast(size_t) i + 1]);
        return target.l[cast(size_t) i];
    }
}

private void expectType(ref const Value v, ValueType t, string site) @safe pure
{
    if (v.type != t)
        failType(site, typeName(t), typeName(v));
}

/// A `str`, or a list whose elements are all `str`, as a string list (type site `site`).
private string[] toStrings(Value v, string site) @safe pure
{
    if (v.type == ValueType.str)
        return [v.s];
    if (v.type != ValueType.list)
        failType(site, "strlist", typeName(v));
    auto r = new string[v.l.length];
    foreach (k, ref e; v.l)
    {
        if (e.type != ValueType.str)
            failType(site, "strlist", typeName(e));
        r[k] = e.s;
    }
    return r;
}

/// `E_BAD_PATH` unless `s` is `@name` or a workspace path.
private void checkReferenceShape(string s) @safe pure
{
    if (s.length > 0 && s[0] == '@')
    {
        if (!isIdentShaped(s[1 .. $]))
            fail("E_BAD_PATH", s);
        return;
    }
    if (!isWorkspacePath(s))
        fail("E_BAD_PATH", s);
}

private void checkOutputPath(string s) @safe pure
{
    if (!isWorkspacePath(s))
        fail("E_BAD_PATH", s);
    if (!isGeneratedPath(s))
        fail("E_OUTPUT_PATH", s);
}
