/**
 * Hindley-Milner inference (Algorithm J) with level-based generalisation.
 *
 * The `Inferencer` owns the type graph and the top-level environment. The
 * environment keeps one binding stack per interned name, so lookup is an
 * array index and generalisation never scans it.
 */
module typeinfer.infer;

import typeinfer.ast;
import typeinfer.errors;
import typeinfer.scheme;
import typeinfer.types;
import typeinfer.unify;

/// A name binding in the environment.
private struct Binding
{
    int name;
    int prev;      /// index of the binding this one shadows, or -1
    TypeId type;
    bool poly;     /// true if `type` may contain quantified variables
}

/// Type inference over parsed programs, with a persistent top-level environment.
final class Inferencer
{
    /// The type graph all inferred types live in.
    TypeStore store;

    private Binding[] binds;     // all live bindings, innermost last
    private int bindCount;
    private int[] top;           // name id -> index of its innermost binding, or -1
    private int level;
    private const(Expr)[] exprs;
    private const(int)[] children;

    ///
    this()
    {
        store = new TypeStore;
        binds = new Binding[256];
    }

    /// Select the program whose expressions subsequent `inferDecl` calls refer to.
    void load(ref const Program program)
    {
        exprs = program.exprs;
        children = program.children;
    }

    /// Make room for name ids below `n`.
    void reserveNames(size_t n)
    {
        immutable old = top.length;
        if (n > old)
        {
            top.length = n;
            top[old .. $] = -1;
        }
    }

    /// Bind `name` at top level to the scheme `type` (used for built-ins).
    void define(int name, TypeId type, bool poly = true)
    {
        reserveNames(name + 1);
        push(name, type, poly);
    }

    /**
     * Infer one top-level declaration of the loaded program.
     *
     * On success a `let`/`let rec` binding is added to the environment and the
     * (generalised) type is returned through `result`. On failure the
     * environment is left as it was.
     *
     * Returns: `ErrorKind.none` or the kind of the first error met.
     */
    ErrorKind inferDecl(in Decl d, out TypeId result)
    {
        immutable mark = bindCount;
        level = 0;
        try
        {
            switch (d.kind)
            {
            case DeclKind.let:
            {
                ++level;
                immutable t = infer(d.expr);
                --level;
                immutable poly = generalize(store, t, level);
                push(d.name, t, poly);
                result = t;
                break;
            }
            case DeclKind.letRec:
            {
                result = inferLetRecBinding(d.name, d.expr);
                push(d.name, result, generalize(store, result, level));
                break;
            }
            default:
                ++level;
                result = infer(d.expr);
                --level;
                break;
            }
            return ErrorKind.none;
        }
        catch (TypeError e)
        {
            unwind(mark);
            return e.kind;
        }
    }

    /**
     * Infer the right-hand side `rhs` of `let rec name` with `name` bound
     * monomorphically to a fresh variable; returns that variable, already
     * unified with the right-hand side's type. The caller generalises it.
     */
    private TypeId inferLetRecBinding(int name, int rhs)
    {
        ++level;
        immutable f = store.newVar(level);
        push(name, f, false);
        immutable t = infer(rhs);
        unify(store, f, t);
        pop();
        --level;
        return f;
    }

    private void push(int name, TypeId type, bool poly)
    {
        if (bindCount == binds.length)
            binds.length = binds.length * 2;
        binds[bindCount] = Binding(name, top[name], type, poly);
        top[name] = bindCount++;
    }

    private void pop()
    {
        --bindCount;
        top[binds[bindCount].name] = binds[bindCount].prev;
    }

    private void unwind(int mark)
    {
        while (bindCount > mark)
            pop();
    }

    private TypeId lookup(int name)
    {
        immutable i = top[name];
        if (i < 0)
            throw new TypeError(ErrorKind.unbound);
        immutable b = binds[i];
        return b.poly ? instantiate(store, b.type, level) : b.type;
    }

    private void expect(TypeId t, TypeId want)
    {
        unify(store, t, want);
    }

    private TypeId infer(int ei)
    {
        immutable Expr e = exprs[ei];
        final switch (e.kind)
        {
        case ExprKind.intLit:
            return TypeStore.intType;
        case ExprKind.boolLit:
            return TypeStore.boolType;
        case ExprKind.unitLit:
            return TypeStore.unitType;
        case ExprKind.variable:
            return lookup(e.a);
        case ExprKind.app:
        {
            immutable tf = infer(e.a);
            immutable ta = infer(e.b);
            immutable f = store.find(tf);
            if (store.nodes[f].kind == NodeKind.arrow)
            {
                // Same as unifying with `ta -> fresh`, without the allocation.
                unify(store, store.nodes[f].a, ta);
                return store.nodes[f].b;
            }
            immutable r = store.newVar(level);
            unify(store, f, store.newArrow(ta, r));
            return r;
        }
        case ExprKind.fun:
        {
            immutable p = store.newVar(level);
            push(e.a, p, false);
            immutable body = infer(e.b);
            pop();
            return store.newArrow(p, body);
        }
        case ExprKind.ifThenElse:
        {
            expect(infer(e.a), TypeStore.boolType);
            immutable ta = infer(e.b);
            immutable tb = infer(e.c);
            unify(store, ta, tb);
            return ta;
        }
        case ExprKind.let:
        {
            ++level;
            immutable t1 = infer(e.b);
            --level;
            immutable poly = generalize(store, t1, level);
            push(e.a, t1, poly);
            immutable t2 = infer(e.c);
            pop();
            return t2;
        }
        case ExprKind.letRec:
        {
            immutable f = inferLetRecBinding(e.a, e.b);
            immutable poly = generalize(store, f, level);
            push(e.a, f, poly);
            immutable t2 = infer(e.c);
            pop();
            return t2;
        }
        case ExprKind.tuple:
        {
            immutable n = e.b;
            immutable start = store.allocPool(n);
            foreach (i; 0 .. n)
            {
                immutable t = infer(children[e.a + i]);
                store.pool[start + i] = t;
            }
            return store.newTupleAt(start, n);
        }
        case ExprKind.list:
        {
            immutable elem = store.newVar(level);
            foreach (i; 0 .. e.b)
                unify(store, elem, infer(children[e.a + i]));
            return store.newList(elem);
        }
        case ExprKind.cons:
        {
            immutable th = infer(e.a);
            immutable tt = infer(e.b);
            immutable l = store.newList(th);
            unify(store, tt, l);
            return l;
        }
        case ExprKind.binary:
        {
            TypeId operand = TypeStore.intType;
            TypeId result = TypeStore.intType;
            final switch (e.op)
            {
            case BinOp.add, BinOp.sub, BinOp.mul, BinOp.div:
                break;
            case BinOp.eq, BinOp.lt, BinOp.gt, BinOp.le, BinOp.ge:
                result = TypeStore.boolType;
                break;
            case BinOp.and, BinOp.or:
                operand = TypeStore.boolType;
                result = TypeStore.boolType;
                break;
            }
            unify(store, infer(e.a), operand);
            unify(store, infer(e.b), operand);
            return result;
        }
        }
    }
}
