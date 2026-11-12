/**
 * Unification, generalisation and instantiation over the shared type graph.
 *
 * Everything here visits each distinct node of a type at most once (types are
 * DAGs, so the expanded tree may be exponentially larger), using a per-walk
 * epoch stamp. Generalisation is level-based, so it never looks at the
 * environment.
 */
module typeinfer.solver;

import typeinfer.types;

/// The three ways inference can fail.
enum ErrorKind : ubyte
{
    /// A variable is not in scope.
    unbound,
    /// Unification would build an infinite type.
    occurs,
    /// Any other unification failure.
    unify,
}

/// Thrown when a declaration does not type-check.
class TypeError : Exception
{
    /// What went wrong.
    ErrorKind kind;

    this(ErrorKind kind, string file = __FILE__, size_t line = __LINE__) @safe nothrow
    {
        super(kind == ErrorKind.unbound ? "unbound variable"
                : kind == ErrorKind.occurs ? "occurs check failed" : "cannot unify", file, line);
        this.kind = kind;
    }
}

/// Owns the current `let` level and walk epochs; provides the core type operations.
final class Solver
{
    private int level_;
    private uint epoch;

    /// Current `let` nesting level.
    int level() const @safe nothrow @nogc { return level_; }

    /// Enters the right-hand side of a `let`: variables created now can be generalised afterwards.
    void enterLevel() @safe nothrow @nogc { ++level_; }

    /// Leaves a `let` right-hand side.
    void leaveLevel() @safe nothrow @nogc { --level_; }

    /// A fresh unbound variable at the current level.
    Type freshVar() @safe nothrow { return Type.newVar(level_); }

    /// A quantified variable, for writing type schemes by hand.
    Type genericVar() @safe nothrow { return Type.newVar(genericLevel); }

    /**
     * Unifies `a` and `b` (left-to-right, component by component), binding
     * variables, with an occurs check at each binding and level adjustment.
     * Throws $(LREF TypeError) (`occurs` or `unify`) on failure.
     */
    void unify(Type a, Type b) @safe 
    {
        a = prune(a);
        b = prune(b);
        if (a is b) return;
        if (a.kind == Kind.var) { bind(a, b); return; }
        if (b.kind == Kind.var) { bind(b, a); return; }
        if (a.kind != b.kind) throw new TypeError(ErrorKind.unify);
        if (a.isBase) return;
        if (a.args.length != b.args.length) throw new TypeError(ErrorKind.unify);
        foreach (i; 0 .. a.args.length) unify(a.args[i], b.args[i]);
        // Equal from now on: merge so that later unifications of these two DAGs are O(1).
        a.link = b;
    }

    /**
     * Quantifies every unbound variable of `t` whose level is above the current
     * level. Returns whether any variable was quantified.
     */
    bool generalize(Type t) @safe nothrow
    {
        ++epoch;
        return gen(t);
    }

    /// Copies `t`, replacing quantified variables by fresh ones at the current level.
    /// Sub-terms without quantified variables are shared with the original.
    Type instantiate(Type t) @safe nothrow
    {
        ++epoch;
        return inst(t);
    }

    // -- internals ----------------------------------------------------------

    private void bind(Type v, Type t) @safe 
    {
        if (t.kind == Kind.var)
        {
            if (t.level > v.level) t.level = v.level;
        }
        else if (!t.isBase)
        {
            ++epoch;
            occurs(v, t);
        }
        v.link = t;
    }

    /// Occurs check of `v` in `t`, lowering the level of every variable reached to `v`'s.
    private void occurs(Type v, Type t) @safe 
    {
        t = prune(t);
        if (t is v) throw new TypeError(ErrorKind.occurs);
        if (t.kind == Kind.var)
        {
            if (t.level > v.level) t.level = v.level;
            return;
        }
        if (t.isBase || t.stamp == epoch) return;
        t.stamp = epoch;
        foreach (ref c; t.args)
        {
            c = prune(c);
            occurs(v, c);
        }
    }

    private bool gen(Type t) @safe nothrow
    {
        t = prune(t);
        if (t.kind == Kind.var)
        {
            if (t.level > level_ && t.level != genericLevel)
            {
                t.level = genericLevel;
                return true;
            }
            return false;
        }
        if (t.isBase || t.stamp == epoch) return false;
        t.stamp = epoch;
        bool any = false;
        foreach (ref c; t.args)
        {
            c = prune(c);
            if (gen(c)) any = true;
        }
        return any;
    }

    private Type inst(Type t) @safe nothrow
    {
        t = prune(t);
        if (t.kind == Kind.var)
        {
            if (t.level != genericLevel) return t;
            if (t.stamp == epoch) return t.copy;
            auto f = Type.newVar(level_);
            t.stamp = epoch;
            t.copy = f;
            return f;
        }
        if (t.isBase) return t;
        if (t.stamp == epoch) return t.copy;
        Type[] na;
        foreach (i, ref c; t.args)
        {
            c = prune(c);
            auto n = inst(c);
            if (n !is c)
            {
                if (na is null) na = t.args.dup;
                na[i] = n;
            }
        }
        Type r = t;
        if (na !is null)
        {
            final switch (t.kind)
            {
                case Kind.fun: r = Type.fun(na[0], na[1]); break;
                case Kind.list: r = Type.list(na[0]); break;
                case Kind.tuple: r = Type.tuple(na); break;
                case Kind.int_, Kind.bool_, Kind.unit, Kind.var: assert(0);
            }
        }
        t.stamp = epoch;
        t.copy = r;
        return r;
    }
}

version (unittest)
{

    private ErrorKind failure(void delegate() @safe dg) @safe
    {
        try dg();
        catch (TypeError e) return e.kind;
        assert(0, "expected a TypeError");
    }
}

@safe unittest
{
    auto s = new Solver;
    auto a = s.freshVar, b = s.freshVar;
    s.unify(Type.fun(a, Type.int_), Type.fun(Type.bool_, b));
    assert(prune(a) is Type.bool_ && prune(b) is Type.int_);
}

@safe unittest
{
    auto s = new Solver;
    auto a = s.freshVar;
    assert(failure({ s.unify(a, Type.list(a)); }) == ErrorKind.occurs);
    assert(failure({ s.unify(Type.int_, Type.bool_); }) == ErrorKind.unify);
    assert(failure({ s.unify(Type.tuple([Type.int_, Type.int_]),
            Type.tuple([Type.int_, Type.int_, Type.int_])); }) == ErrorKind.unify);
}

@safe unittest
{
    // Occurs is detected before the later, clashing components are reached.
    auto s = new Solver;
    auto a = s.freshVar;
    assert(failure({
        s.unify(Type.tuple([a, Type.int_]), Type.tuple([Type.list(a), Type.bool_]));
    }) == ErrorKind.occurs);
}

@safe unittest
{
    // Generalise at level 0, instantiate twice: independent copies.
    auto s = new Solver;
    s.enterLevel();
    auto a = s.freshVar;
    auto t = Type.fun(a, a);
    s.leaveLevel();
    assert(s.generalize(t));
    auto i1 = s.instantiate(t), i2 = s.instantiate(t);
    s.unify(i1, Type.fun(Type.int_, Type.int_));
    s.unify(i2, Type.fun(Type.bool_, Type.bool_));
}

@safe unittest
{
    // Variables that belong to an outer level are not generalised, and the
    // levels of variables reached by unification are lowered.
    auto s = new Solver;
    auto outer = s.freshVar;           // level 0
    s.enterLevel();
    auto inner = s.freshVar;           // level 1
    s.unify(outer, Type.list(inner));  // inner is now owned by level 0
    s.leaveLevel();
    assert(!s.generalize(Type.list(inner)));
    assert(!s.generalize(outer));
}

@safe unittest
{
    // Instantiation shares sub-terms that contain no quantified variable.
    auto s = new Solver;
    auto mono = Type.list(Type.int_);
    s.enterLevel();
    auto a = s.freshVar;
    auto t = Type.tuple([mono, Type.fun(a, mono)]);
    s.leaveLevel();
    s.generalize(t);
    auto i = prune(s.instantiate(t));
    assert(i !is t && prune(i.args[0]) is mono);
}

@safe unittest
{
    // A DAG whose expansion is 2^40 leaves is handled in linear time.
    auto s = new Solver;
    s.enterLevel();
    Type t = s.freshVar;
    foreach (_; 0 .. 40) t = Type.tuple([t, t]);
    s.leaveLevel();
    assert(s.generalize(t));
    auto i = s.instantiate(t);
    auto j = s.instantiate(t);
    s.unify(i, j);
    s.unify(i, j);
}
