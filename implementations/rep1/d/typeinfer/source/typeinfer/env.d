/**
 * The typing environment: a name maps to its innermost binding.
 */
module typeinfer.env;

import typeinfer.types;

/// What a name is bound to.
struct Binding
{
    /// The type (a scheme if `poly`).
    Type type;
    /// True when `type` has quantified variables and must be instantiated at each use.
    bool poly;
}

/**
 * Scoped name environment with O(1) lookup, binding and unbinding.
 *
 * Bindings made with $(LREF push) are recorded on a trail so that a scope
 * can be left with $(LREF popTo), restoring any shadowed binding.
 */
final class Env
{
    private struct Saved
    {
        string name;
        Binding prev;
        bool had;
    }

    private Binding[string] map;
    private Saved[] trail;   // trail[0 .. top] is live
    private size_t top;

    /// Finds the innermost binding of `name`. Returns false if it is unbound.
    bool lookup(string name, out Binding b) @safe nothrow
    {
        if (auto p = name in map)
        {
            b = *p;
            return true;
        }
        return false;
    }

    /// A marker for the current scope depth, to pass to $(LREF popTo).
    size_t mark() const @safe nothrow @nogc { return top; }

    /// Binds `name`, shadowing any existing binding until the scope is popped.
    void push(string name, Type type, bool poly) @safe nothrow
    {
        Saved s = Saved(name, Binding.init, false);
        if (auto p = name in map)
        {
            s.prev = *p;
            s.had = true;
        }
        if (top == trail.length) trail ~= s;
        else trail[top] = s;
        ++top;
        map[name] = Binding(type, poly);
    }

    /// Undoes every `push` made since `mark` was taken.
    void popTo(size_t mark) @safe nothrow
    {
        while (top > mark)
        {
            --top;
            auto s = trail[top];
            trail[top] = Saved.init;
            if (s.had) map[s.name] = s.prev;
            else map.remove(s.name);
        }
    }

    /// Makes all bindings pushed so far permanent.
    void commit() @safe nothrow
    {
        foreach (ref s; trail[0 .. top]) s = Saved.init;
        top = 0;
    }
}

@safe nothrow unittest
{
    auto e = new Env;
    e.push("x", Type.int_, false);
    e.commit();
    auto m = e.mark;
    e.push("x", Type.bool_, false);
    e.push("y", Type.unit, false);
    Binding b;
    assert(e.lookup("x", b) && b.type is Type.bool_ && e.lookup("y", b));
    e.popTo(m);
    assert(e.lookup("x", b) && b.type is Type.int_ && !e.lookup("y", b));
}
