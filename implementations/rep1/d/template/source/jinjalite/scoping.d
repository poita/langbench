/// Lexical scopes: a chain of small name tables with O(1) creation.
module jinjalite.scoping;

import jinjalite.value;

/++
    A mapping from names to values plus a parent scope. Creating a scope is
    O(1); a lookup walks the chain, so it costs O(depth). Scopes with many
    bindings switch from a linear scan to a hash index.
+/
final class Scope
{
    private Scope parent_;
    private string[] names_;
    private Value[] values_;
    private size_t[string] index_;
    private Dict dict_;

    private enum indexThreshold = 8;

    /// A fresh empty scope below `parent` (which may be `null`).
    this(Scope parent) pure nothrow @safe @nogc
    {
        parent_ = parent;
    }

    /// A root scope whose bindings are the members of `dict` (shared, not copied).
    this(Scope parent, Dict dict) pure nothrow @safe @nogc
    {
        parent_ = parent;
        dict_ = dict;
    }

    /// The enclosing scope.
    Scope parent() pure nothrow @safe @nogc
    {
        return parent_;
    }

    /// Bind `name` in this scope, replacing an existing binding of this scope only.
    void set(string name, Value value)
    {
        if (dict_ !is null)
        {
            dict_.set(name, value);
            return;
        }
        if (names_.length > indexThreshold)
        {
            if (auto p = name in index_)
            {
                values_[*p] = value;
                return;
            }
        }
        else
        {
            foreach (idx, existing; names_)
                if (existing == name)
                {
                    values_[idx] = value;
                    return;
                }
        }
        names_ ~= name;
        values_ ~= value;
        if (names_.length > indexThreshold)
        {
            if (names_.length == indexThreshold + 1)
                foreach (idx, n; names_)
                    index_[n] = idx;
            else
                index_[name] = names_.length - 1;
        }
    }

    /// Look `name` up in this scope and its ancestors; `null` when unbound.
    Value* lookup(string name)
    {
        for (Scope s = this; s !is null; s = s.parent_)
        {
            if (s.dict_ !is null)
            {
                if (auto p = s.dict_.find(name))
                    return p;
            }
            else if (s.names_.length > indexThreshold)
            {
                if (auto p = name in s.index_)
                    return &s.values_[*p];
            }
            else
            {
                foreach (idx, existing; s.names_)
                    if (existing == name)
                        return &s.values_[idx];
            }
        }
        return null;
    }
}

unittest
{
    auto root = new Scope(null);
    root.set("a", Value.integer(1));
    auto inner = new Scope(root);
    inner.set("b", Value.integer(2));
    inner.set("a", Value.integer(10)); // shadows, does not modify the parent
    assert(inner.lookup("a").i == 10);
    assert(root.lookup("a").i == 1);
    assert(root.lookup("b") is null);
    assert(inner.lookup("b").i == 2);
    assert(inner.parent is root);
}

unittest
{
    import std.conv : to;
    auto s = new Scope(null);
    foreach (i; 0 .. 100)
        s.set("n" ~ i.to!string, Value.integer(i));
    s.set("n50", Value.integer(-1));
    foreach (i; 0 .. 100)
        assert(s.lookup("n" ~ i.to!string).i == (i == 50 ? -1 : i));
    assert(s.lookup("zz") is null);
}

unittest
{
    auto d = new Dict;
    d.set("x", Value.text("ctx"));
    auto root = new Scope(null, d);
    auto child = new Scope(root);
    assert(child.lookup("x").s == "ctx");
    assert(child.lookup("y") is null);
}
