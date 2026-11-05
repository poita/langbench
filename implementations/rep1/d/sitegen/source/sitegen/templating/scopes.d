/// Lexical scopes of the template interpreter.
module sitegen.templating.scopes;

import sitegen.templating.value;

/// A frame of variable bindings with a parent frame.
///
/// Scopes hold only a handful of names, so bindings are kept in small
/// parallel arrays searched linearly; lookups walk the parent chain.
final class Scope
{
    Scope parent;
    string[] names;
    Value[] values;

    this(Scope parent = null) pure nothrow @safe
    {
        this.parent = parent;
    }

    /// Bind `name` in this scope, replacing a previous binding made here.
    void set(string name, Value v) pure nothrow @safe
    {
        foreach (k, n; names)
            if (n == name)
            {
                values[k] = v;
                return;
            }
        names ~= name;
        values ~= v;
    }

    /// Bind without checking for an existing binding.
    package void add(string name, Value v) pure nothrow @safe
    {
        names ~= name;
        values ~= v;
    }

    /// Look `name` up in this scope and its ancestors.
    bool lookup(string name, out Value v) pure nothrow @safe
    {
        for (Scope s = this; s !is null; s = s.parent)
        {
            foreach_reverse (k, n; s.names)
                if (n == name)
                {
                    v = s.values[k];
                    return true;
                }
        }
        return false;
    }
}
