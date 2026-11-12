/**
 * The tree-walking interpreter: evaluates build files into steps, phony
 * targets and default targets.
 */
module kiln.eval;

import kiln.ast;
import kiln.builtins;
import kiln.commands;
import kiln.errors;
import kiln.parser;
import kiln.step;
import kiln.text;
import kiln.value;
import kiln.vfs;

/// A lexical scope: bindings plus a parent pointer.
final class Scope
{
    ///
    Scope parent;
    ///
    Value[string] vars;

    ///
    this(Scope parent = null) @safe pure nothrow @nogc { this.parent = parent; }

    /// Finds the innermost scope binding `name`, or null.
    Scope find(string name) @safe pure nothrow
    {
        for (auto s = this; s !is null; s = s.parent)
            if (name in s.vars)
                return s;
        return null;
    }
}

/// A declared phony target.
struct Phony
{
    /// Name without the `@`.
    string name;
    /// Validated dependency references (`@name` or paths).
    string[] deps;
}

private final class Rule
{
    string name;
    Param[] params;
    Stmt[] body_;
    Scope defScope;
}

/// The result of evaluating the build files of a workspace.
final class Evaluation
{
    /// Steps in serial order.
    Step[] steps;
    /// Phony targets in declaration order.
    Phony[] phonies;
    /// The default target list (duplicates kept).
    string[] defaults;
}

/// Maximum rule instantiation depth.
enum maxRuleDepth = 64;

/// Evaluates `main.kiln` (and its includes) against `fs`.
///
/// Throws: `KilnError` for the first error encountered.
Evaluation evaluateWorkspace(Vfs fs)
{
    if (!fs.exists("main.kiln"))
        throw new KilnError("E_NO_BUILD_FILE", "main.kiln");
    auto interp = new Interpreter(fs);
    return interp.run("main.kiln");
}

private final class Interpreter
{
    Vfs fs;
    Evaluation result;
    Rule[string] rules;
    bool[string] phonyNames;
    string[] includeStack;
    int depth;

    this(Vfs fs)
    {
        this.fs = fs;
        result = new Evaluation;
    }

    Evaluation run(string mainPath)
    {
        auto root = new Scope;
        runFile(mainPath, root);
        return result;
    }

    void runFile(string path, Scope sc)
    {
        auto file = parseBuildFile(path, fs.read(path));
        includeStack ~= path;
        execBody(file.statements, sc);
        includeStack = includeStack[0 .. $ - 1];
    }

    void execBody(Stmt[] body_, Scope sc)
    {
        foreach (s; body_)
            exec(s, sc);
    }

    void exec(Stmt s, Scope sc)
    {
        final switch (s.kind)
        {
        case Stmt.Kind.let:
        {
            auto v = eval(s.expr, sc);
            if (s.name in sc.vars)
                throw new KilnError("E_REDEFINE", s.name);
            sc.vars[s.name] = v;
            break;
        }
        case Stmt.Kind.set:
        {
            auto v = eval(s.expr, sc);
            auto target = sc.find(s.name);
            if (target is null)
                throw new KilnError("E_SET_UNDEFINED", s.name);
            target.vars[s.name] = v;
            break;
        }
        case Stmt.Kind.include:
            execInclude(s, sc);
            break;
        case Stmt.Kind.abort:
        {
            auto v = eval(s.expr, sc);
            if (v.type != Value.Type.str)
                throw typeError("abort message", "str", v.typeName);
            throw new KilnError("E_ABORT", v.text);
        }
        case Stmt.Kind.default_:
            result.defaults ~= stringList(eval(s.expr, sc), "default");
            break;
        case Stmt.Kind.phony:
            execPhony(s, sc);
            break;
        case Stmt.Kind.use:
            execUse(s, sc);
            break;
        case Stmt.Kind.when:
            execWhen(s, sc);
            break;
        case Stmt.Kind.each:
        {
            auto subject = eval(s.expr, sc);
            if (subject.type != Value.Type.list)
                throw typeError("each subject", "list", subject.typeName);
            foreach (i, ref item; subject.items)
            {
                auto inner = new Scope(sc);
                if (s.indexName !is null)
                    inner.vars[s.indexName] = Value.ofInt(cast(long) i);
                inner.vars[s.name] = item;
                execBody(s.body_, inner);
            }
            break;
        }
        case Stmt.Kind.rule:
        {
            if (s.name in rules)
                throw new KilnError("E_REDEFINE", s.name);
            auto r = new Rule;
            r.name = s.name;
            r.params = s.params;
            r.body_ = s.body_;
            r.defScope = sc;
            rules[s.name] = r;
            break;
        }
        case Stmt.Kind.step:
            execStep(s, sc);
            break;
        }
    }

    void execInclude(Stmt s, Scope sc)
    {
        auto v = eval(s.expr, sc);
        if (v.type != Value.Type.str)
            throw typeError("include path", "str", v.typeName);
        if (!isWorkspacePath(v.text))
            throw new KilnError("E_BAD_PATH", v.text);
        if (!fs.exists(v.text))
            throw new KilnError("E_INCLUDE_MISSING", v.text);
        foreach (p; includeStack)
            if (p == v.text)
                throw new KilnError("E_INCLUDE_CYCLE", v.text);
        runFile(v.text, sc);
    }

    void execPhony(Stmt s, Scope sc)
    {
        auto v = eval(s.expr, sc);
        auto deps = stringList(v, "phony " ~ s.name);
        foreach (d; deps)
            checkReference(d);
        if (s.name in phonyNames)
            throw new KilnError("E_DUP_PHONY", s.name);
        phonyNames[s.name] = true;
        result.phonies ~= Phony(s.name, deps);
    }

    void execWhen(Stmt s, Scope sc)
    {
        foreach (i, cond; s.conds)
        {
            auto c = eval(cond, sc);
            if (c.type != Value.Type.boolean)
                throw typeError("when condition", "bool", c.typeName);
            if (c.asBool)
            {
                execBody(s.bodies[i], new Scope(sc));
                return;
            }
        }
        if (s.hasOtherwise)
            execBody(s.bodies[$ - 1], new Scope(sc));
    }

    void execUse(Stmt s, Scope sc)
    {
        import std.conv : to;

        auto rp = s.name in rules;
        if (rp is null)
            throw new KilnError("E_UNKNOWN_RULE", s.name);
        auto rule = *rp;
        if (depth + 1 > maxRuleDepth)
            throw new KilnError("E_RULE_RECURSION", s.name);
        Value[] values;
        foreach (ref a; s.useArgs)
            values ~= eval(a.value, sc);
        auto inner = new Scope(rule.defScope);
        size_t positional = 0;
        foreach (ref a; s.useArgs)
            if (a.keyword is null)
                ++positional;
        if (positional > rule.params.length)
            throw new KilnError("E_ARITY", "rule " ~ rule.name ~ ": expected " ~ rule.params.length.to!string
                    ~ ", got " ~ positional.to!string);
        foreach (i; 0 .. positional)
            inner.vars[rule.params[i].name] = values[i];
        foreach (i, ref a; s.useArgs)
        {
            if (a.keyword is null)
                continue;
            bool known = false;
            foreach (ref p; rule.params)
                if (p.name == a.keyword)
                    known = true;
            if (!known)
                throw new KilnError("E_ARG", "rule " ~ rule.name ~ ": unknown argument " ~ a.keyword);
            if (a.keyword in inner.vars)
                throw new KilnError("E_ARG", "rule " ~ rule.name ~ ": duplicate argument " ~ a.keyword);
            inner.vars[a.keyword] = values[i];
        }
        foreach (ref p; rule.params)
        {
            if (p.name in inner.vars)
                continue;
            if (p.defaultValue is null)
                throw new KilnError("E_ARG", "rule " ~ rule.name ~ ": missing argument " ~ p.name);
            inner.vars[p.name] = eval(p.defaultValue, inner);
        }
        ++depth;
        scope (exit)
            --depth;
        execBody(rule.body_, inner);
    }

    // ---- steps -----------------------------------------------------------

    void execStep(Stmt s, Scope sc)
    {
        auto st = new Step;
        st.serial = cast(int) result.steps.length;
        result.steps ~= st;
        bool haveCost = false, haveCmd = false;
        long cost;
        foreach (ref f; s.fields)
        {
            final switch (f.kind)
            {
            case StepField.Kind.out_:
                st.outs ~= stringList(eval(f.expr, sc), "field out");
                break;
            case StepField.Kind.in_:
                st.ins ~= stringList(eval(f.expr, sc), "field in");
                break;
            case StepField.Kind.after:
                st.afters ~= stringList(eval(f.expr, sc), "field after");
                break;
            case StepField.Kind.cost:
            {
                if (haveCost)
                    throw new KilnError("E_STEP_FIELD", "duplicate cost");
                auto v = eval(f.expr, sc);
                if (v.type != Value.Type.integer)
                    throw typeError("field cost", "int", v.typeName);
                if (v.num < 0)
                    throw new KilnError("E_ARG", "field cost: negative");
                haveCost = true;
                cost = v.num;
                break;
            }
            case StepField.Kind.depfile:
            {
                if (st.hasDepfile)
                    throw new KilnError("E_STEP_FIELD", "duplicate depfile");
                auto v = eval(f.expr, sc);
                if (v.type != Value.Type.str)
                    throw typeError("field depfile", "str", v.typeName);
                st.hasDepfile = true;
                st.depfile = v.text;
                break;
            }
            case StepField.Kind.cmd:
                if (haveCmd)
                    throw new KilnError("E_STEP_FIELD", "duplicate cmd");
                haveCmd = true;
                buildCommand(st, f, sc);
                break;
            }
        }
        validateStep(st, haveCmd, haveCost, cost);
    }

    void buildCommand(Step st, ref StepField f, Scope sc)
    {
        import std.conv : to;

        auto spec = findCommand(f.cmdName);
        if (spec is null)
            throw new KilnError("E_UNKNOWN_CMD", f.cmdName);
        Value[] args;
        foreach (e; f.cmdArgs)
            args ~= eval(e, sc);
        if (args.length != spec.args.length)
            throw new KilnError("E_ARITY", "cmd " ~ spec.name ~ ": expected " ~ spec.args.length.to!string
                    ~ ", got " ~ args.length.to!string);
        foreach (i, ref a; args)
            if (a.type != spec.args[i])
                throw typeError("cmd " ~ spec.name ~ " argument " ~ (i + 1).to!string,
                        spec.args[i] == Value.Type.str ? "str" : "int", a.typeName);
        st.cmdName = spec.name;
        st.cmdArgs = args;
    }

    void validateStep(Step st, bool haveCmd, bool haveCost, long cost)
    {
        import std.conv : to;

        if (!haveCmd)
            throw new KilnError("E_STEP_FIELD", "missing cmd");
        if (st.outs.length == 0)
            throw new KilnError("E_STEP_FIELD", "missing out");
        foreach (p; st.outs)
            checkOutputPath(p);
        if (st.hasDepfile)
            checkOutputPath(st.depfile);
        foreach (p; st.ins)
            checkReference(p);
        foreach (p; st.afters)
            checkReference(p);
        foreach (p; st.ins)
            if (!startsWithBytes(p, "@"))
                st.fileInputs ~= p;
        const spec = findCommand(st.cmdName);
        const m = st.fileInputs.length;
        if (m < spec.minInputs || m > spec.maxInputs)
        {
            const lo = spec.minInputs.to!string;
            const hi = spec.maxInputs == size_t.max ? "N" : spec.maxInputs.to!string;
            throw new KilnError("E_CMD_SHAPE", spec.name ~ ": expected inputs " ~ lo ~ "-" ~ hi ~ ", got " ~ m.to!string);
        }
        if (st.outs.length != 1)
            throw new KilnError("E_CMD_SHAPE", spec.name ~ ": expected outputs 1, got " ~ st.outs.length.to!string);
        if (spec.usesDepfile && !st.hasDepfile)
            throw new KilnError("E_CMD_SHAPE", spec.name ~ ": depfile required");
        if (!spec.usesDepfile && st.hasDepfile)
            throw new KilnError("E_CMD_SHAPE", spec.name ~ ": depfile not allowed");
        if (spec.name == "replace" && st.cmdArgs[0].text.length == 0)
            throw new KilnError("E_ARG", "cmd replace: empty pattern");
        if (spec.name == "indent" && st.cmdArgs[0].num < 0)
            throw new KilnError("E_ARG", "cmd indent: negative");
        st.cost = haveCost ? cost : spec.defaultCost;
        st.cmdString = canonicalCommand(st.cmdName, st.cmdArgs);
        st.fullOuts = st.outs.dup;
        if (st.hasDepfile)
            st.fullOuts ~= st.depfile;
    }

    static void checkOutputPath(string p)
    {
        if (!isWorkspacePath(p))
            throw new KilnError("E_BAD_PATH", p);
        if (!isGeneratedPath(p))
            throw new KilnError("E_OUTPUT_PATH", p);
    }

    static void checkReference(string p)
    {
        if (startsWithBytes(p, "@"))
        {
            if (!isIdentShaped(p[1 .. $]))
                throw new KilnError("E_BAD_PATH", p);
        }
        else if (!isWorkspacePath(p))
            throw new KilnError("E_BAD_PATH", p);
    }

    /// Converts a `str` or list-of-`str` value to a string array (E_TYPE `strlist` otherwise).
    static string[] stringList(Value v, string site)
    {
        if (v.type == Value.Type.str)
            return [v.text];
        if (v.type != Value.Type.list)
            throw typeError(site, "strlist", v.typeName);
        string[] r;
        foreach (ref e; v.items)
        {
            if (e.type != Value.Type.str)
                throw typeError(site, "strlist", e.typeName);
            r ~= e.text;
        }
        return r;
    }

    // ---- expressions -----------------------------------------------------

    Value lookup(string name, Scope sc)
    {
        for (auto s = sc; s !is null; s = s.parent)
            if (auto p = name in s.vars)
                return *p;
        throw new KilnError("E_UNKNOWN_VAR", name);
    }

    Value eval(Expr e, Scope sc)
    {
        final switch (e.kind)
        {
        case Expr.Kind.literal:
            return e.lit;
        case Expr.Kind.interp:
        {
            char[] buf;
            foreach (ref p; e.parts)
            {
                if (p.expr is null)
                {
                    buf ~= p.literal;
                    continue;
                }
                auto v = eval(p.expr, sc);
                if (v.type == Value.Type.list)
                    throw new KilnError("E_INTERP", "list");
                buf ~= scalarText(v);
            }
            return Value.ofStr(buf.idup);
        }
        case Expr.Kind.variable:
            return lookup(e.name, sc);
        case Expr.Kind.list:
        {
            auto items = new Value[e.args.length];
            foreach (i, a; e.args)
                items[i] = eval(a, sc);
            return Value.ofList(items);
        }
        case Expr.Kind.unary:
        {
            auto v = eval(e.args[0], sc);
            if (e.name == "!")
            {
                if (v.type != Value.Type.boolean)
                    throw typeError("operator !", "bool", v.typeName);
                return Value.ofBool(!v.asBool);
            }
            if (v.type != Value.Type.integer)
                throw typeError("operator -", "int", v.typeName);
            return Value.ofInt(0 - v.num);
        }
        case Expr.Kind.binary:
            return evalBinary(e, sc);
        case Expr.Kind.call:
            return evalCall(e, sc);
        case Expr.Kind.index:
        {
            auto x = eval(e.args[0], sc);
            auto i = eval(e.args[1], sc);
            if (i.type != Value.Type.integer)
                throw typeError("index", "int", i.typeName);
            if (x.type != Value.Type.str && x.type != Value.Type.list)
                throw typeError("index target", "str|list", x.typeName);
            const n = cast(long)(x.type == Value.Type.str ? x.text.length : x.items.length);
            long k = i.num;
            if (k < 0)
                k += n;
            if (i.num < -n || i.num >= n)
                throw new KilnError("E_ARG", "fn index: out of range");
            if (x.type == Value.Type.str)
                return Value.ofStr(x.text[cast(size_t) k .. cast(size_t) k + 1]);
            return x.items[cast(size_t) k];
        }
        }
    }

    Value evalBinary(Expr e, Scope sc)
    {
        const op = e.name;
        if (op == "||" || op == "&&")
        {
            auto l = eval(e.args[0], sc);
            if (l.type != Value.Type.boolean)
                throw typeError("operator " ~ op, "bool", l.typeName);
            if (op == "||" && l.asBool)
                return l;
            if (op == "&&" && !l.asBool)
                return l;
            auto r = eval(e.args[1], sc);
            if (r.type != Value.Type.boolean)
                throw typeError("operator " ~ op, "bool", r.typeName);
            return r;
        }
        auto l = eval(e.args[0], sc);
        auto r = eval(e.args[1], sc);
        switch (op)
        {
        case "==": return Value.ofBool(valuesEqual(l, r));
        case "!=": return Value.ofBool(!valuesEqual(l, r));
        case "<": return Value.ofBool(compareValues(l, r) < 0);
        case "<=": return Value.ofBool(compareValues(l, r) <= 0);
        case ">": return Value.ofBool(compareValues(l, r) > 0);
        case ">=": return Value.ofBool(compareValues(l, r) >= 0);
        case "++":
            requireType(op, l, Value.Type.list, "list");
            requireType(op, r, Value.Type.list, "list");
            return Value.ofList(l.items ~ r.items);
        case "~":
            requireType(op, l, Value.Type.str, "str");
            requireType(op, r, Value.Type.str, "str");
            return Value.ofStr(l.text ~ r.text);
        default:
            break;
        }
        requireType(op, l, Value.Type.integer, "int");
        requireType(op, r, Value.Type.integer, "int");
        switch (op)
        {
        case "+": return Value.ofInt(l.num + r.num);
        case "-": return Value.ofInt(l.num - r.num);
        case "*": return Value.ofInt(l.num * r.num);
        case "/":
        case "%":
            if (r.num == 0)
                throw new KilnError("E_DIV_ZERO");
            if (r.num == -1)
                return Value.ofInt(op == "/" ? 0 - l.num : 0);
            return Value.ofInt(op == "/" ? l.num / r.num : l.num % r.num);
        default:
            assert(false, "unknown operator " ~ op);
        }
    }

    static void requireType(string op, ref Value v, Value.Type t, string name)
    {
        if (v.type != t)
            throw typeError("operator " ~ op, name, v.typeName);
    }

    Value evalCall(Expr e, Scope sc)
    {
        auto b = findBuiltin(e.name);
        if (b is null)
            throw new KilnError("E_UNKNOWN_FUNC", e.name);
        auto args = new Value[e.args.length];
        foreach (i, a; e.args)
            args[i] = eval(a, sc);
        checkCall(b, args);
        return b.run(args, fs);
    }
}

version (unittest)
{
    private string evalWs(string[string] files, string main = null)
    {
        auto fs = new Vfs;
        foreach (k, v; files)
            fs.write(k, v);
        if (main !is null)
            fs.write("main.kiln", main);
        try
        {
            auto ev = evaluateWorkspace(fs);
            string r;
            foreach (s; ev.steps)
                r ~= s.primary ~ ":" ~ s.cmdString ~ ";";
            foreach (d; ev.defaults)
                r ~= "d=" ~ d ~ ";";
            return r;
        }
        catch (KilnError e)
            return e.msg;
    }
}

unittest
{
    assert(evalWs(null) == "E_NO_BUILD_FILE main.kiln");
    assert(evalWs(null, "let x = 1\nlet x = 2\n") == "E_REDEFINE x");
    assert(evalWs(null, "let x = 1\nwhen true {\n let x = 2\n set x = x + 1\n}\nset y = 1\n") == "E_SET_UNDEFINED y");
    assert(evalWs(null, "let x = \"a\" + 1\n") == "E_TYPE operator +: expected int, got str");
    assert(evalWs(null, "let x = 1 / 0\n") == "E_DIV_ZERO");
    assert(evalWs(null, "let x = 5[\"a\"]\n") == "E_TYPE index: expected int, got str");
    assert(evalWs(null, "let x = \"{[1]}\"\n") == "E_INTERP list");
    assert(evalWs(null, "let x = nope(undefined)\n") == "E_UNKNOWN_FUNC nope");
    assert(evalWs(null, "let x = upper(undefined, 2)\n") == "E_UNKNOWN_VAR undefined");
    assert(evalWs(null, "let x = true || (1/0 == 1)\nlet y = false && z\nabort \"n={-7 % 3}\"\n") == "E_ABORT n=-1");
    assert(evalWs(null, "let x = \"abc\"[-1] ~ [1,2][0] \n") == "E_TYPE operator ~: expected str, got int");
}

unittest
{
    assert(evalWs(null, "step {\n out \"out/a\"\n cmd write(\"x\")\n}\ndefault \"out/a\"\n")
            == `out/a:write("x");d=out/a;`);
    assert(evalWs(null, "step {\n cmd write(\"x\")\n}\n") == "E_STEP_FIELD missing out");
    assert(evalWs(null, "step {\n out \"a\"\n cmd write(\"x\")\n}\n") == "E_OUTPUT_PATH a");
    assert(evalWs(null, "step {\n out \"out/a\"\n cmd concat()\n}\n") == "E_CMD_SHAPE concat: expected inputs 1-N, got 0");
    assert(evalWs(null, "step {\n out \"out/a\"\n cmd write(1)\n}\n") == "E_TYPE cmd write argument 1: expected str, got int");
    assert(evalWs(null, "step {\n out \"out/a\"\n cmd write(\"x\")\n cost 1\n cost nope\n}\n")
            == "E_STEP_FIELD duplicate cost");
    assert(evalWs(null, "rule r(a, b = a ++ [1]) {\n let z = b\n}\nuse r([0])\nuse r(1, 2, 3)\n")
            == "E_ARITY rule r: expected 2, got 3");
    assert(evalWs(null, "rule r(a) {\n use r(a)\n}\nuse r(1)\n") == "E_RULE_RECURSION r");
    assert(evalWs(["a.kiln": "include \"main.kiln\"\n"], "include \"a.kiln\"\n") == "E_INCLUDE_CYCLE main.kiln");
}
