/**
 * The initial environment.
 */
module typeinfer.builtins;

import typeinfer.env;
import typeinfer.solver;
import typeinfer.types;

/// Adds the built-in functions (`not fst snd hd tl null length map fold`) to `env`.
void addBuiltins(Env env, Solver s) @safe nothrow
{
    alias fn = Type.fun;
    auto I = Type.int_, B = Type.bool_;

    env.push("not", fn(B, B), false);
    {
        auto a = s.genericVar, b = s.genericVar;
        auto p = Type.tuple([a, b]);
        env.push("fst", fn(p, a), true);
        env.push("snd", fn(p, b), true);
    }
    {
        auto a = s.genericVar;
        env.push("hd", fn(Type.list(a), a), true);
        env.push("tl", fn(Type.list(a), Type.list(a)), true);
        env.push("null", fn(Type.list(a), B), true);
        env.push("length", fn(Type.list(a), I), true);
    }
    {
        auto a = s.genericVar, b = s.genericVar;
        env.push("map", fn(fn(a, b), fn(Type.list(a), Type.list(b))), true);
    }
    {
        auto a = s.genericVar, b = s.genericVar;
        env.push("fold", fn(fn(a, fn(b, a)), fn(a, fn(Type.list(b), a))), true);
    }
    env.commit();
}
