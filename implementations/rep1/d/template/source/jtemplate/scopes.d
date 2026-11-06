/// Lexical scopes and per-rendering state.
module jtemplate.scopes;

import jtemplate.ast : BlockNode, Template;
import jtemplate.value;

/// A mapping from names to values plus a parent scope.
///
/// Scopes created during rendering hold only a few names, so they use two
/// parallel arrays searched linearly; a hash index is added once a scope
/// grows past [Scope.indexThreshold] names. The root scope wraps the JSON
/// context dictionary directly. Creating a child scope never copies anything
/// from its parent.
final class Scope
{
    /// Number of names after which a hash index is maintained.
    enum indexThreshold = 12;

    /// Enclosing scope, or null for the root.
    Scope parent;

    private DictObj root_;          // non-null for the root scope
    private string[] names_;
    private Value[] vals_;
    private size_t count_;
    private size_t[string] index_;  // used once count_ > indexThreshold

    /// Create a scope with the given parent and room for `capacity` names.
    this(Scope parent, size_t capacity = 0) pure nothrow @safe
    {
        this.parent = parent;
        if (capacity)
        {
            names_ = new string[capacity];
            vals_ = new Value[capacity];
        }
    }

    /// Create a root scope whose bindings are the members of `context`.
    static Scope makeRoot(DictObj context) nothrow @safe
    {
        auto s = new Scope(null);
        s.root_ = context;
        return s;
    }

    /// Forget every binding (used to recycle a loop-iteration scope).
    void reset() nothrow @safe
    {
        count_ = 0;
        if (index_.length) index_ = null;
    }

    /// Append a binding without checking whether the name is already bound.
    void bindNew(string name, Value v) nothrow @trusted
    {
        if (count_ == names_.length)
        {
            immutable cap = count_ < 4 ? 4 : count_ * 2;
            auto nn = new string[cap];
            auto nv = new Value[cap];
            nn[0 .. count_] = names_[0 .. count_];
            nv[0 .. count_] = vals_[0 .. count_];
            names_ = nn;
            vals_ = nv;
        }
        names_[count_] = name;
        vals_[count_] = v;
        ++count_;
        if (count_ == indexThreshold + 1)
        {
            foreach (i; 0 .. count_)
                index_[names_[i]] = i;
        }
        else if (count_ > indexThreshold + 1)
            index_[name] = count_ - 1;
    }

    /// Bind `name` in this scope, replacing an existing binding made here.
    void bind(string name, Value v) nothrow @trusted
    {
        if (auto p = findLocal(name))
            *p = v;
        else
            bindNew(name, v);
    }

    /// Set the value of the `i`-th binding of this scope (fast path for
    /// macro parameters, which are bound by position).
    void setSlot(size_t i, Value v) nothrow @safe @nogc { vals_[i] = v; }

    /// Read the `i`-th binding of this scope.
    Value slot(size_t i) const nothrow @safe @nogc { return vals_[i]; }

    /// Pointer to this scope's own binding for `name`, or null.
    Value* findLocal(const(char)[] name) nothrow @trusted
    {
        if (root_ !is null)
            return root_.find(name);
        if (count_ > indexThreshold)
        {
            if (auto p = name in index_)
                return &vals_[*p];
            return null;
        }
        foreach_reverse (i; 0 .. count_)
        {
            immutable n = names_[i];
            if (n.length == name.length && (n.ptr is name.ptr || n == name))
                return &vals_[i];
        }
        return null;
    }

    /// Look `name` up in this scope and its ancestors; undefined if unbound.
    Value lookup(const(char)[] name) nothrow @trusted
    {
        for (Scope s = this; s !is null; s = s.parent)
        {
            if (auto p = s.findLocal(name))
            {
                if (p.kind != Kind.unset)
                    return *p;
            }
        }
        return Value.undef;
    }
}

/// State of one rendering (the main template, or one `include`): the scope
/// shared by a template and its ancestors, and the block override chains.
final class Rendering
{
    /// The template scope; parents of `extends` run in it as well.
    Scope templateScope;
    /// For each block name, bodies from most to least derived.
    BlockNode[][string] chains;
    /// Set by an executing `extends` tag: the template to run next.
    Template pendingParent;

    ///
    this(Scope templateScope) pure nothrow @safe
    {
        this.templateScope = templateScope;
    }

    /// Append every block of `t` to the chain of the same name.
    void addBlocks(Template t)
    {
        foreach (name, node; t.blocks)
            chains[name] ~= node;
    }
}
