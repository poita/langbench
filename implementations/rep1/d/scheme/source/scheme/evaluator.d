/**
 * The evaluator: runs analysed `Node` trees.
 *
 * Calls in tail position never grow the host stack: `eval` is a loop that
 * rebinds `n` and `env` and goes round again (a trampoline in the form of a
 * `for` loop). Non-tail sub-evaluations (operands, tests, `let` inits, ...)
 * recurse, so non-tail Scheme recursion nests on the host stack; run on a
 * thread with a generous stack if you need very deep recursion.
 */
module scheme.evaluator;

import scheme.ast;
import scheme.environment;
import scheme.output;
import scheme.value;

/// Evaluates analysed programs, writing program output to an `Output`.
final class Evaluator
{
    private Output output;

    this(Output output)
    {
        this.output = output;
    }

    /// Evaluate `node` in `env` (`null` is the global environment).
    Value eval(Node node, Frame env)
    {
        Node n = node;
        Value f;
        Value[] args;
        for (;;)
        {
            final switch (n.kind)
            {
            case NodeKind.constant:
                return n.val;

            case NodeKind.ref_:
                return lookup(n.sym, env);

            case NodeKind.set:
                {
                    Value v = eval(n.a, env);
                    assign(n.sym, v, env);
                    return Value.void_();
                }

            case NodeKind.define:
                {
                    Value v = eval(n.a, env);
                    if (env is null)
                    {
                        n.sym.value = v;
                        n.sym.bound = true;
                    }
                    else
                        env.define(n.sym, v);
                    return Value.void_();
                }

            case NodeKind.if_:
                if (eval(n.a, env).isTrue)
                    n = n.b;
                else if (n.c is null)
                    return Value.void_();
                else
                    n = n.c;
                continue;

            case NodeKind.lambda:
                return Value.fromClosure(new Closure(n.lambda, env));

            case NodeKind.seq:
                {
                    auto kids = n.kids;
                    foreach (i; 0 .. kids.length - 1)
                        eval(kids[i], env);
                    n = kids[$ - 1];
                    continue;
                }

            case NodeKind.and:
                {
                    auto kids = n.kids;
                    foreach (i; 0 .. kids.length - 1)
                    {
                        Value v = eval(kids[i], env);
                        if (!v.isTrue)
                            return v;
                    }
                    n = kids[$ - 1];
                    continue;
                }

            case NodeKind.or:
                {
                    auto kids = n.kids;
                    foreach (i; 0 .. kids.length - 1)
                    {
                        Value v = eval(kids[i], env);
                        if (v.isTrue)
                            return v;
                    }
                    n = kids[$ - 1];
                    continue;
                }

            case NodeKind.let:
                {
                    auto kids = n.kids;
                    auto vals = new Value[kids.length];
                    foreach (i; 0 .. kids.length)
                        vals[i] = eval(kids[i], env);
                    env = new Frame(env, n.syms, vals, vals.length);
                    n = n.a;
                    continue;
                }

            case NodeKind.letrec:
                {
                    auto kids = n.kids;
                    auto fr = new Frame(env, new Symbol[kids.length], new Value[kids.length], 0);
                    foreach (i; 0 .. kids.length)
                    {
                        Value v = eval(kids[i], fr);
                        fr.names[i] = n.syms[i];
                        fr.vals[i] = v;
                        fr.n = i + 1;
                    }
                    env = fr;
                    n = n.a;
                    continue;
                }

            case NodeKind.namedLet:
                {
                    auto kids = n.kids;
                    args = new Value[kids.length];
                    foreach (i; 0 .. kids.length)
                        args[i] = eval(kids[i], env);
                    // `name` lives in a frame of its own between env and the call frame.
                    auto nameFrame = new Frame(env, [n.sym], new Value[1], 1);
                    f = Value.fromClosure(new Closure(n.lambda, nameFrame));
                    nameFrame.vals[0] = f;
                    break; // to the application below
                }

            case NodeKind.app:
                {
                    f = eval(n.a, env);
                    auto kids = n.kids;
                    args = new Value[kids.length];
                    foreach (i; 0 .. kids.length)
                        args[i] = eval(kids[i], env);
                    break;
                }
            }

            // Apply `f` to `args`. Closures continue the outer loop (tail call).
            for (;;)
            {
                if (f.kind == Kind.closure)
                {
                    auto c = f.closure;
                    auto info = c.info;
                    if (!info.variadic)
                    {
                        if (args.length != info.params.length)
                            throw new SchemeError(ErrorKind.arityError);
                        env = new Frame(c.env, info.params, args, args.length);
                    }
                    else
                    {
                        if (args.length < info.required)
                            throw new SchemeError(ErrorKind.arityError);
                        auto vals = new Value[info.required + 1];
                        vals[0 .. info.required] = args[0 .. info.required];
                        vals[info.required] = listFromArray(args[info.required .. $]);
                        env = new Frame(c.env, info.params, vals, vals.length);
                    }
                    n = info.body_;
                    break;
                }
                if (f.kind != Kind.primitive)
                    throw new SchemeError(ErrorKind.typeError);
                auto p = f.prim;
                if (args.length < p.minArgs || args.length > p.maxArgs)
                    throw new SchemeError(ErrorKind.arityError);
                if (!p.isApply)
                    return p.fn(args, output);

                // (apply f a ... lst): spread the final list and call f again.
                Value[] spread = args[1 .. $ - 1].dup;
                Value lst = args[$ - 1];
                while (lst.kind == Kind.pair)
                {
                    spread ~= lst.pair.car;
                    lst = lst.pair.cdr;
                }
                if (lst.kind != Kind.nil)
                    throw new SchemeError(ErrorKind.typeError);
                f = args[0];
                args = spread;
            }
        }
    }

    private static Value lookup(Symbol s, Frame env)
    {
        for (Frame fr = env; fr !is null; fr = fr.parent)
        {
            auto names = fr.names;
            foreach (i; 0 .. fr.n)
                if (names[i] is s)
                    return fr.vals[i];
        }
        if (s.bound)
            return s.value;
        throw new SchemeError(ErrorKind.unboundVariable);
    }

    private static void assign(Symbol s, Value v, Frame env)
    {
        for (Frame fr = env; fr !is null; fr = fr.parent)
        {
            auto names = fr.names;
            foreach (i; 0 .. fr.n)
                if (names[i] is s)
                {
                    fr.vals[i] = v;
                    return;
                }
        }
        if (!s.bound)
            throw new SchemeError(ErrorKind.unboundVariable);
        s.value = v;
    }
}
