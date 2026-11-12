/**
 * Algorithm J: one left-to-right pass over the syntax tree that unifies as it goes.
 */
module typeinfer.infer;

import typeinfer.ast;
import typeinfer.builtins;
import typeinfer.env;
import typeinfer.printer;
import typeinfer.solver;
import typeinfer.types;

/// The outcome of checking one top-level declaration.
struct DeclResult
{
    /// Bound name, or empty for a bare expression.
    string name;
    /// True if the declaration type-checked.
    bool ok;
    /// Why it failed (meaningful when `!ok`).
    ErrorKind error;
    /// The rendered type (meaningful when `ok`).
    string type;

    /// The output line for this declaration, without the trailing newline.
    string toString() const @safe nothrow
    {
        if (!ok)
        {
            final switch (error)
            {
                case ErrorKind.unify: return "error: unify";
                case ErrorKind.occurs: return "error: occurs";
                case ErrorKind.unbound: return "error: unbound";
            }
        }
        return (name.length ? name : "-") ~ " : " ~ type;
    }
}

/**
 * Infers types for a sequence of declarations, keeping the top-level environment
 * between calls to $(LREF check).
 *
 * Inference recurses over the syntax tree and the types, so very deep input
 * needs a deep call stack (see the command-line tool, which runs it on a
 * thread with a large stack).
 */
final class Inferencer
{
    private Solver solver;
    private Env env;

    /// Creates an inferencer whose environment holds only the built-ins.
    this() @safe nothrow
    {
        solver = new Solver;
        env = new Env;
        addBuiltins(env, solver);
    }

    /// Checks one declaration. A successful binding is added to the environment;
    /// a failed one leaves the environment unchanged.
    DeclResult check(Decl d) @safe 
    {
        DeclResult r;
        r.name = d.name;
        try
        {
            assert(solver.level == 0 && env.mark == 0);
            solver.enterLevel();
            Type t;
            if (d.isRec)
                t = inferRec(d.name, d.expr);
            else
                t = infer(d.expr);
            solver.leaveLevel();
            bool poly = d.isBinding ? solver.generalize(t) : false;
            r.type = typeToString(t);
            r.ok = true;
            if (d.isBinding)
            {
                env.push(d.name, t, poly);
                env.commit();
            }
        }
        catch (TypeError e)
        {
            env.popTo(0);
            while (solver.level > 0) solver.leaveLevel();
            r.ok = false;
            r.error = e.kind;
        }
        return r;
    }

    /// Infers the type of `e` in the current environment.
    Type infer(Expr e) @safe 
    {
        final switch (e.kind)
        {
            case ExprKind.intLit: return Type.int_;
            case ExprKind.boolLit: return Type.bool_;
            case ExprKind.unitLit: return Type.unit;
            case ExprKind.nil: return Type.list(solver.freshVar);
            case ExprKind.var: return inferVar(cast(Var) e);
            case ExprKind.lam: return inferLam(cast(Lam) e);
            case ExprKind.app: return inferApp(cast(App) e);
            case ExprKind.let: return inferLet(cast(Let) e);
            case ExprKind.ifThenElse: return inferIf(cast(If) e);
            case ExprKind.tuple: return inferTuple(cast(Tuple) e);
            case ExprKind.list: return inferList(cast(ListLit) e);
            case ExprKind.binary: return inferBinary(cast(Binary) e);
            case ExprKind.cons: return inferCons(cast(Cons) e);
        }
    }

private:

    Type inferVar(Var v) @safe 
    {
        Binding b;
        if (!env.lookup(v.name, b)) throw new TypeError(ErrorKind.unbound);
        return b.poly ? solver.instantiate(b.type) : b.type;
    }

    Type inferLam(Lam l) @safe 
    {
        immutable mark = env.mark;
        auto ps = new Type[l.params.length];
        foreach (i, name; l.params)
        {
            ps[i] = solver.freshVar;
            env.push(name, ps[i], false);
        }
        Type r = infer(l.body);
        env.popTo(mark);
        foreach_reverse (p; ps) r = Type.fun(p, r);
        return r;
    }

    Type inferApp(App a) @safe 
    {
        auto tf = infer(a.fn);
        auto ta = infer(a.arg);
        auto r = solver.freshVar;
        solver.unify(tf, Type.fun(ta, r));
        return r;
    }

    /// Infers the right-hand side of a `let rec` named `name`, returning the (monomorphic) type of `name`.
    /// The caller has already entered the right-hand side's level.
    Type inferRec(string name, Expr rhs) @safe 
    {
        immutable mark = env.mark;
        auto f = solver.freshVar;
        env.push(name, f, false);
        auto t = infer(rhs);
        solver.unify(f, t);
        env.popTo(mark);
        return f;
    }

    Type inferLet(Let l) @safe 
    {
        solver.enterLevel();
        auto t = l.isRec ? inferRec(l.name, l.rhs) : infer(l.rhs);
        solver.leaveLevel();
        immutable poly = solver.generalize(t);
        immutable mark = env.mark;
        env.push(l.name, t, poly);
        auto r = infer(l.body);
        env.popTo(mark);
        return r;
    }

    Type inferIf(If i) @safe 
    {
        solver.unify(infer(i.cond), Type.bool_);
        auto a = infer(i.thenBranch);
        auto b = infer(i.elseBranch);
        solver.unify(a, b);
        return a;
    }

    Type inferTuple(Tuple t) @safe 
    {
        auto ts = new Type[t.elems.length];
        foreach (i, e; t.elems) ts[i] = infer(e);
        return Type.tuple(ts);
    }

    Type inferList(ListLit l) @safe 
    {
        auto elem = solver.freshVar;
        foreach (e; l.elems) solver.unify(elem, infer(e));
        return Type.list(elem);
    }

    Type inferBinary(Binary b) @safe 
    {
        Type operand, result;
        final switch (b.op)
        {
            case BinOp.add, BinOp.sub, BinOp.mul, BinOp.div:
                operand = result = Type.int_;
                break;
            case BinOp.eq, BinOp.lt, BinOp.gt, BinOp.le, BinOp.ge:
                operand = Type.int_;
                result = Type.bool_;
                break;
            case BinOp.and, BinOp.or:
                operand = result = Type.bool_;
                break;
        }
        solver.unify(infer(b.lhs), operand);
        solver.unify(infer(b.rhs), operand);
        return result;
    }

    Type inferCons(Cons c) @safe 
    {
        auto h = infer(c.head);
        auto t = infer(c.tail);
        solver.unify(t, Type.list(h));
        return t;
    }
}

version (unittest)
{
    import typeinfer.parser : parseProgram;

    /// Checks `src` with a fresh inferencer and returns the output lines.
    string[] lines(string src) @safe 
    {
        auto inf = new Inferencer;
        string[] r;
        foreach (d; parseProgram(src)) r ~= inf.check(d).toString;
        return r;
    }
}

@safe unittest
{
    assert(lines("fun x -> x;;") == ["- : 'a -> 'a"]);
    assert(lines("let k x y = x;; k;;") == ["k : 'a -> 'b -> 'a", "- : 'a -> 'b -> 'a"]);
    assert(lines("1 + 2 * 3;; 1 < 2;; true && false;;") == ["- : int", "- : bool", "- : bool"]);
    assert(lines("();; [];; [1; 2];; 1 :: [];;") == ["- : unit", "- : 'a list", "- : int list", "- : int list"]);
}

@safe unittest
{
    // let-polymorphism, no value restriction.
    assert(lines("let id x = x;; let g = id id;; (g 1, g true);;")
            == ["id : 'a -> 'a", "g : 'a -> 'a", "- : int * bool"]);
    // lambda-bound variables are monomorphic.
    assert(lines("fun f -> (f 1, f true);;") == ["error: unify"]);
    assert(lines("let rec bad x = bad 1 + bad true;;") == ["error: unify"]);
    assert(lines("let rec len l = if null l then 0 else 1 + len (tl l);;")
            == ["len : 'a list -> int"]);
}

@safe unittest
{
    // Errors, their precedence, and recovery.
    assert(lines("fun x -> x x;;") == ["error: occurs"]);
    assert(lines("true + undefined;;") == ["error: unify"]);
    assert(lines("undefined + true;;") == ["error: unbound"]);
    assert(lines("fun x -> if true then (x, 0) else ([x], true);;") == ["error: occurs"]);
    assert(lines("let g = id id;; let id = fun x -> x;; let g = id id;;")
            == ["error: unbound", "id : 'a -> 'a", "g : 'a -> 'a"]);
    // A failed declaration does not rebind, and scopes unwind properly.
    assert(lines("let x = 1;; let x = (fun y -> let z = 1 in y z) 2;; x;;")
            == ["x : int", "error: unify", "- : int"]);
}

@safe unittest
{
    // Shadowing and `let` not seeing its own name.
    assert(lines("let map = 3;; map;;") == ["map : int", "- : int"]);
    assert(lines("let x = 1;; let x = x + 1;; (let x = true in x);;")
            == ["x : int", "x : int", "- : bool"]);
    assert(lines("let x = x;;") == ["error: unbound"]);
}
