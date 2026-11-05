/// The evaluator: a single trampolined loop over compiled nodes.
module scheme.interp;

import core.thread : Thread;
import scheme.compiler;
import scheme.errors;
import scheme.node;
import scheme.output;
import scheme.primitives;
import scheme.printer;
import scheme.reader;
import scheme.symbols;
import scheme.value;

/// A Scheme interpreter with its own global environment and output buffer.
///
/// Example:
/// ---
/// auto interp = new Interpreter;
/// string out_ = interp.run("(display (+ 1 2)) (newline) (* 6 7)");
/// assert(out_ == "3\n42\n");
/// ---
final class Interpreter
{
    private SymbolTable syms;
    private Output output;
    private Context cx;
    private PrimDef[] prims;
    private int applyId;
    private Value[] globals;   // indexed by symbol id
    private Value[] stack;     // shared argument stack
    private size_t sp;

    /// Create an interpreter whose global environment holds the primitives.
    this()
    {
        syms = new SymbolTable;
        output = new Output;
        cx = new Context(syms, output);
        prims = makePrimitives();
        stack = new Value[1024];
        foreach (id, p; prims)
        {
            int sym = syms.intern(p.name);
            growGlobals();
            globals[sym] = Value.prim(cast(int) id);
            if (p.name == applyName)
                applyId = cast(int) id;
        }
    }

    /// Everything written so far (program output and error lines).
    const(char)[] outputSoFar() const { return output.data; }

    /// Evaluate a whole program and return its output. A runtime error ends
    /// evaluation and appends `error: <category>` to the output; it is not
    /// reported as a D exception.
    ///
    /// Non-tail Scheme recursion uses the host stack, so the program is
    /// evaluated on a helper thread with a `stackSize`-byte stack.
    string run(string source)
    {
        string result;
        Throwable failure;
        auto t = new Thread({
            try
                result = runHere(source);
            catch (Throwable e)
                failure = e;
        }, stackSize);
        t.start();
        t.join();
        if (failure !is null)
            throw failure;
        return result;
    }

    /// Stack size, in bytes, of the evaluator thread used by `run`.
    enum stackSize = 256UL * 1024 * 1024;

    /// Like `run`, but evaluates on the calling thread's stack.
    string runHere(string source)
    {
        auto reader = Reader(source, syms);
        Compiler compiler;
        try
        {
            Value form;
            while (reader.next(form))
            {
                Node node = compiler.compile(form);
                growGlobals();
                Value v = eval(node, null);
                if (v.tag != Tag.voidValue)
                {
                    print(output, syms, v, false);
                    output.put('\n');
                }
            }
        }
        catch (SchemeError e)
        {
            output.put("error: ");
            output.put(e.msg);
            output.put('\n');
            sp = 0;
        }
        return output.data.idup;
    }

    private void growGlobals()
    {
        if (globals.length < syms.length)
            globals.length = syms.length;
    }

    private void push(Value v)
    {
        if (sp == stack.length)
            stack.length = stack.length * 2;
        stack[sp++] = v;
    }

    private Value lookup(int sym, Frame* env)
    {
        for (; env !is null; env = env.parent)
        {
            auto ids = env.ids;
            foreach (k; 0 .. ids.length)
                if (ids[k] == sym)
                    return env.vals[k];
        }
        Value v = globals[sym];
        if (v.tag == Tag.unbound)
            unboundVariable();
        return v;
    }

    private void assign(int sym, Value v, Frame* env)
    {
        for (; env !is null; env = env.parent)
        {
            auto ids = env.ids;
            foreach (k; 0 .. ids.length)
                if (ids[k] == sym)
                {
                    env.vals[k] = v;
                    return;
                }
        }
        if (globals[sym].tag == Tag.unbound)
            unboundVariable();
        globals[sym] = v;
    }

    /// Evaluate a subform, short-cutting the commonest leaf nodes.
    pragma(inline, true)
    private Value evalSub(Node n, Frame* env)
    {
        if (n.kind == Kind.constant)
            return n.val;
        if (n.kind == Kind.variable)
            return lookup(n.sym, env);
        return eval(n, env);
    }

    /// Evaluate `n` in `env` (null is the global environment).
    private Value eval(Node n, Frame* env)
    {
        outer:
        for (;;)
        {
            Value f;
            size_t base;
            final switch (n.kind)
            {
            case Kind.constant:
                return n.val;
            case Kind.variable:
                return lookup(n.sym, env);
            case Kind.set:
            {
                Value v = eval(n.a, env);
                assign(n.sym, v, env);
                return Value.voidValue;
            }
            case Kind.define:
            {
                Value v = eval(n.a, env);
                if (env is null)
                    globals[n.sym] = v;
                else
                    env.define(n.sym, v);
                return Value.voidValue;
            }
            case Kind.if_:
                if (evalSub(n.a, env).truthy)
                    n = n.b;
                else if (n.c !is null)
                    n = n.c;
                else
                    return Value.voidValue;
                continue outer;
            case Kind.lambda:
                return closureValue(new Closure(n.proc, env));
            case Kind.begin:
            {
                auto kids = n.kids;
                foreach (k; kids[0 .. $ - 1])
                    eval(k, env);
                n = kids[$ - 1];
                continue outer;
            }
            case Kind.and:
            {
                auto kids = n.kids;
                foreach (k; kids[0 .. $ - 1])
                {
                    Value v = eval(k, env);
                    if (!v.truthy)
                        return v;
                }
                n = kids[$ - 1];
                continue outer;
            }
            case Kind.or:
            {
                auto kids = n.kids;
                foreach (k; kids[0 .. $ - 1])
                {
                    Value v = eval(k, env);
                    if (v.truthy)
                        return v;
                }
                n = kids[$ - 1];
                continue outer;
            }
            case Kind.cond:
            {
                foreach (ref cl; n.clauses)
                {
                    if (cl.isElse)
                    {
                        if (cl.body is null)
                            return Value.voidValue;
                        n = cl.body;
                        continue outer;
                    }
                    Value t = eval(cl.test, env);
                    if (t.truthy)
                    {
                        if (cl.body is null)
                            return t;
                        n = cl.body;
                        continue outer;
                    }
                }
                return Value.voidValue;
            }
            case Kind.let:
            {
                base = sp;
                foreach (init; n.inits)
                    push(evalSub(init, env));
                env = Frame.create(env, n.names, stack[base .. sp], true);
                sp = base;
                n = n.body;
                continue outer;
            }
            case Kind.letStar:
            {
                if (n.names.length == 0)
                    env = Frame.create(env, null, 0, false);
                foreach (k, init; n.inits)
                {
                    Value v = eval(init, env);
                    {
                        env = Frame.create(env, n.names[k .. k + 1], 1, true);
                        env.vals[0] = v;
                    }
                }
                n = n.body;
                continue outer;
            }
            case Kind.letrec:
            {
                auto fr = Frame.create(env, null, 0, false);
                foreach (k, init; n.inits)
                    fr.define(n.names[k], eval(init, fr));
                env = fr;
                n = n.body;
                continue outer;
            }
            case Kind.namedLet:
            {
                base = sp;
                foreach (init; n.inits)
                    push(evalSub(init, env));
                auto loopFrame = Frame.create(env, n.names, 1, true);
                f = closureValue(new Closure(n.proc, loopFrame));
                loopFrame.vals[0] = f;
                break;
            }
            case Kind.app:
            {
                f = evalSub(n.a, env);
                base = sp;
                foreach (arg; n.kids)
                    push(evalSub(arg, env));
                break;
            }
            }

            // Apply `f` to the arguments in stack[base .. sp].
            for (;;)
            {
                if (f.tag == Tag.closure)
                {
                    Closure c = asClosure(f);
                    Proc pr = c.proc;
                    size_t argc = sp - base;
                    if (!pr.rest)
                    {
                        if (argc != pr.nfixed)
                            arityError();
                        env = Frame.create(c.env, pr.ids, stack[base .. sp], true);
                    }
                    else
                    {
                        if (argc < pr.nfixed)
                            arityError();
                        env = Frame.create(c.env, pr.ids, pr.nfixed + 1, true);
                        env.vals[0 .. pr.nfixed] = stack[base .. base + pr.nfixed];
                        Value lst = Value.nil;
                        for (size_t i = sp; i > base + pr.nfixed; --i)
                            lst = Value.cons(stack[i - 1], lst);
                        env.vals[pr.nfixed] = lst;
                    }
                    sp = base;
                    n = pr.body;
                    continue outer;
                }
                if (f.tag != Tag.prim)
                {
                    sp = base;
                    typeError();
                }
                auto def = &prims[cast(size_t) f.i];
                size_t argc = sp - base;
                if (argc < def.minArgs || (def.maxArgs >= 0 && argc > def.maxArgs))
                    arityError();
                if (f.i == applyId)
                {
                    f = spliceApply(base);
                    continue;
                }
                Value r = def.fn(stack[base .. sp], cx);
                sp = base;
                return r;
            }
        }
        assert(0);
    }

    /// Rearrange the stack for `(apply f a ... lst)`: returns `f`, leaving
    /// `a ... elements-of-lst` in stack[base .. sp].
    private Value spliceApply(size_t base)
    {
        Value fn = stack[base];
        Value lst = stack[sp - 1];
        size_t count = 0;
        for (Value l = lst; ; l = l.pair.cdr)
        {
            if (l.tag == Tag.nil)
                break;
            if (l.tag != Tag.pair)
                typeError();
            ++count;
        }
        size_t mid = sp - 1 - (base + 1); // leading args between f and lst
        size_t newSp = base + mid + count;
        while (newSp > stack.length)
            stack.length = stack.length * 2;
        foreach (k; 0 .. mid)
            stack[base + k] = stack[base + 1 + k];
        size_t at = base + mid;
        for (Value l = lst; l.tag == Tag.pair; l = l.pair.cdr)
            stack[at++] = l.pair.car;
        sp = newSp;
        return fn;
    }
}
