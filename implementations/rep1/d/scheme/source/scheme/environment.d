/**
 * Environments: a chain of small frames ending in the global environment.
 *
 * The global environment is represented by a `null` frame; global bindings
 * live in the `Symbol` objects themselves (see `scheme.value`).
 */
module scheme.environment;

import scheme.value;

/**
 * One level of local bindings. Names are looked up by identity, innermost
 * frame first. `names`/`vals` may initially alias arrays owned by the code
 * (the parameter list of a lambda), so they are copied before growing.
 */
final class Frame
{
    Frame parent;
    Symbol[] names;
    Value[] vals;
    /// Number of live bindings (`names[0 .. n]`).
    size_t n;

    this(Frame parent, Symbol[] names, Value[] vals, size_t n) pure nothrow @nogc @safe
    {
        this.parent = parent;
        this.names = names;
        this.vals = vals;
        this.n = n;
    }

    /// Bind `s` in this frame, replacing an existing binding of the same name.
    void define(Symbol s, Value v) nothrow
    {
        foreach (i; 0 .. n)
            if (names[i] is s)
            {
                vals[i] = v;
                return;
            }
        if (n == names.length)
        {
            size_t cap = n < 4 ? 4 : n * 2;
            auto nn = new Symbol[cap];
            auto nv = new Value[cap];
            nn[0 .. n] = names[0 .. n];
            nv[0 .. n] = vals[0 .. n];
            names = nn;
            vals = nv;
        }
        names[n] = s;
        vals[n] = v;
        ++n;
    }
}
