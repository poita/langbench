/// Semantic types, type inference variables and the entities the checker
/// resolves names to (SPEC.md sections 6 to 9).
module langvm.types;

import langvm.ast;
import langvm.diag : Pos;

// ---------------------------------------------------------------- types

/// The form of a semantic type.
enum TK : ubyte
{
    int_, float_, bool_, char_, str, unit, list, map, tuple, fn, named, param, var,
}

/// A semantic type.
final class Type
{
    TK kind;
    /// list: `[elem]`; map: `[key, value]`; tuple: components; fn: parameters;
    /// named: type arguments.
    Type[] args;
    /// fn: the return type.
    Type ret;
    /// named: the struct or enum declaration.
    TypeDecl decl;
    /// param: the rigid generic parameter.
    TypeParam param;
    /// var: the type this inference variable was solved to (null while unsolved).
    Type link;

    this(TK kind)
    {
        this.kind = kind;
    }
}

__gshared Type tInt, tFloat, tBool, tChar, tStr, tUnit;

shared static this()
{
    tInt = new Type(TK.int_);
    tFloat = new Type(TK.float_);
    tBool = new Type(TK.bool_);
    tChar = new Type(TK.char_);
    tStr = new Type(TK.str);
    tUnit = new Type(TK.unit);
}

/// `[elem]`
Type mkList(Type elem)
{
    auto t = new Type(TK.list);
    t.args = [elem];
    return t;
}

/// `#[k: v]`
Type mkMap(Type k, Type v)
{
    auto t = new Type(TK.map);
    t.args = [k, v];
    return t;
}

/// `(a, b, ...)`
Type mkTuple(Type[] comps)
{
    auto t = new Type(TK.tuple);
    t.args = comps;
    return t;
}

/// `fn(params) -> ret`
Type mkFn(Type[] params, Type ret)
{
    auto t = new Type(TK.fn);
    t.args = params;
    t.ret = ret;
    return t;
}

/// `Decl<args>`
Type mkNamed(TypeDecl decl, Type[] args)
{
    auto t = new Type(TK.named);
    t.decl = decl;
    t.args = args;
    return t;
}

/// A fresh, unsolved inference variable.
Type newVar()
{
    return new Type(TK.var);
}

/// Follow solved variables to the type they stand for.
Type prune(Type t)
{
    while (t.kind == TK.var && t.link !is null)
        t = t.link;
    return t;
}

/// Substitute every solved variable, returning a type with no solved variables
/// left in it (unsolved ones stay).
Type zonk(Type t)
{
    t = prune(t);
    final switch (t.kind)
    {
    case TK.int_, TK.float_, TK.bool_, TK.char_, TK.str, TK.unit, TK.param, TK.var:
        return t;
    case TK.list, TK.map, TK.tuple, TK.fn, TK.named:
        bool changed = false;
        Type[] a = new Type[t.args.length];
        foreach (i, x; t.args)
        {
            a[i] = zonk(x);
            changed |= a[i] !is x;
        }
        Type r = t.ret is null ? null : zonk(t.ret);
        if (!changed && r is t.ret)
            return t;
        auto n = new Type(t.kind);
        n.args = a;
        n.ret = r;
        n.decl = t.decl;
        return n;
    }
}

/// Does `t` contain an unsolved inference variable?
bool hasUnsolved(Type t)
{
    t = prune(t);
    if (t.kind == TK.var)
        return true;
    foreach (x; t.args)
        if (hasUnsolved(x))
            return true;
    return t.ret !is null && hasUnsolved(t.ret);
}

private bool occurs(Type v, Type t)
{
    t = prune(t);
    if (t is v)
        return true;
    foreach (x; t.args)
        if (occurs(v, x))
            return true;
    return t.ret !is null && occurs(v, t.ret);
}

/// Unify two types (SPEC.md section 9.2). Variables are bound directly with
/// the occurs check; on failure some bindings may remain, which is fine
/// because the caller then reports an error.
bool unify(Type a, Type b)
{
    a = prune(a);
    b = prune(b);
    if (a is b)
        return true;
    if (a.kind == TK.var)
    {
        if (occurs(a, b))
            return false;
        a.link = b;
        return true;
    }
    if (b.kind == TK.var)
    {
        if (occurs(b, a))
            return false;
        b.link = a;
        return true;
    }
    if (a.kind != b.kind)
        return false;
    switch (a.kind)
    {
    case TK.param:
        return a.param is b.param;
    case TK.named:
        if (a.decl !is b.decl)
            return false;
        goto case TK.list;
    case TK.list, TK.map, TK.tuple, TK.fn:
        if (a.args.length != b.args.length)
            return false;
        foreach (i; 0 .. a.args.length)
            if (!unify(a.args[i], b.args[i]))
                return false;
        if (a.kind == TK.fn)
            return unify(a.ret, b.ret);
        return true;
    default:
        return true; // same primitive
    }
}

/// Structural equality of two (already ground) types.
bool typeEq(Type a, Type b)
{
    a = prune(a);
    b = prune(b);
    if (a is b)
        return true;
    if (a.kind != b.kind)
        return false;
    switch (a.kind)
    {
    case TK.var:
        return false;
    case TK.param:
        return a.param is b.param;
    case TK.named:
        if (a.decl !is b.decl)
            return false;
        goto case TK.list;
    case TK.list, TK.map, TK.tuple, TK.fn:
        if (a.args.length != b.args.length)
            return false;
        foreach (i; 0 .. a.args.length)
            if (!typeEq(a.args[i], b.args[i]))
                return false;
        if (a.kind == TK.fn)
            return typeEq(a.ret, b.ret);
        return true;
    default:
        return true;
    }
}

/// Replace each parameter in `ps` by the corresponding type in `with_`.
Type subst(Type t, const(TypeParam)[] ps, Type[] with_)
{
    if (ps.length == 0)
        return t;
    t = prune(t);
    switch (t.kind)
    {
    case TK.param:
        foreach (i, p; ps)
            if (p is t.param)
                return with_[i];
        return t;
    case TK.list, TK.map, TK.tuple, TK.fn, TK.named:
        bool changed = false;
        Type[] a = new Type[t.args.length];
        foreach (i, x; t.args)
        {
            a[i] = subst(x, ps, with_);
            changed |= a[i] !is x;
        }
        Type r = t.ret is null ? null : subst(t.ret, ps, with_);
        if (!changed && r is t.ret)
            return t;
        auto n = new Type(t.kind);
        n.args = a;
        n.ret = r;
        n.decl = t.decl;
        return n;
    default:
        return t;
    }
}

/// Does the rigid parameter `p` occur in `t`?
bool mentionsParam(Type t, const TypeParam p)
{
    t = prune(t);
    if (t.kind == TK.param && t.param is p)
        return true;
    foreach (x; t.args)
        if (mentionsParam(x, p))
            return true;
    return t.ret !is null && mentionsParam(t.ret, p);
}

/// Human-readable rendering, for debugging and tests.
string typeStr(Type t)
{
    import std.array : join;
    import std.algorithm : map;
    import std.conv : to;

    t = prune(t);
    final switch (t.kind)
    {
    case TK.int_:
        return "Int";
    case TK.float_:
        return "Float";
    case TK.bool_:
        return "Bool";
    case TK.char_:
        return "Char";
    case TK.str:
        return "Str";
    case TK.unit:
        return "Unit";
    case TK.list:
        return "[" ~ typeStr(t.args[0]) ~ "]";
    case TK.map:
        return "#[" ~ typeStr(t.args[0]) ~ ": " ~ typeStr(t.args[1]) ~ "]";
    case TK.tuple:
        return "(" ~ t.args.map!(typeStr).join(", ") ~ ")";
    case TK.fn:
        return "fn(" ~ t.args.map!(typeStr).join(", ") ~ ") -> " ~ typeStr(t.ret);
    case TK.named:
        return t.decl.name ~ (t.args.length ? "<" ~ t.args.map!(typeStr).join(", ") ~ ">" : "");
    case TK.param:
        return t.param.name;
    case TK.var:
        return "?";
    }
}

// ---------------------------------------------------------------- head constructors

/// Constructor numbers: the six primitives, then `List`, `Map`, then one per
/// struct/enum declaration. Used to key impls and for run-time dispatch.
enum Ctor : int
{
    int_ = 0, float_, bool_, char_, str, unit, list, map,
    firstDecl = 8,
}

/// The head constructor of a type, or -1 when it has none (tuples, functions,
/// parameters).
int headCtor(Type t)
{
    t = prune(t);
    switch (t.kind)
    {
    case TK.int_: return Ctor.int_;
    case TK.float_: return Ctor.float_;
    case TK.bool_: return Ctor.bool_;
    case TK.char_: return Ctor.char_;
    case TK.str: return Ctor.str;
    case TK.unit: return Ctor.unit;
    case TK.list: return Ctor.list;
    case TK.map: return Ctor.map;
    case TK.named: return Ctor.firstDecl + t.decl.id;
    default: return -1;
    }
}

// ---------------------------------------------------------------- entities

/// A rigid generic parameter together with its declared bounds.
final class TypeParam
{
    string name;
    /// Built-in bounds.
    bool eq, ord, key;
    /// User trait bounds.
    TraitInfo[] bounds;
    /// The type that denotes this parameter.
    Type type;

    this(string name)
    {
        this.name = name;
        type = new Type(TK.param);
        type.param = this;
    }

    bool hasBound(const TraitInfo t) const
    {
        foreach (b; bounds)
            if (b is t)
                return true;
        return false;
    }
}

/// A struct field.
struct Field
{
    string name;
    Type type;
}

/// A struct or enum declaration.
final class TypeDecl
{
    string name;
    int id;
    int module_;
    bool pub;
    bool isEnum;
    Pos pos;
    TypeParam[] tparams;
    Field[] fields;
    VariantInfo[] variants;

    int fieldIndex(string n) const
    {
        foreach (i, f; fields)
            if (f.name == n)
                return cast(int) i;
        return -1;
    }

    /// The type `Name<P1, ..., Pn>` over its own parameters.
    Type selfType()
    {
        Type[] a;
        foreach (p; tparams)
            a ~= p.type;
        return mkNamed(this, a);
    }
}

/// A variant of an enum.
final class VariantInfo
{
    string name;
    TypeDecl decl;
    int index;
    Type[] payload;
    Pos pos;
}

/// A method as declared by a trait.
final class MethodSig
{
    string name;
    int index;
    /// Parameter types, not counting `self`; may mention the trait's `Self` parameter.
    Type[] params;
    Type ret;
    FnDecl decl;
    /// The default body, or null.
    FnInfo defaultFn;
}

/// A trait: user-declared or one of the built-ins `Eq`, `Ord`, `Key`.
final class TraitInfo
{
    string name;
    int id;
    int module_;
    bool pub;
    bool builtin;
    /// The rigid parameter standing for `Self` inside the trait.
    TypeParam selfParam;
    MethodSig[] methods;
    TraitDecl decl;
    /// Registered impls, keyed by head constructor.
    ImplInfo[int] impls;

    int methodIndex(string n) const
    {
        foreach (i, m; methods)
            if (m.name == n)
                return cast(int) i;
        return -1;
    }
}

/// A function, built-in, impl method or trait default method.
final class FnInfo
{
    string name;
    int module_;
    bool pub;
    TypeParam[] tparams;
    /// Parameter types; for methods the first one is `self`.
    Type[] params;
    Type ret;
    FnDecl decl;
    /// >= 0 for a built-in function.
    int builtinId = -1;
    /// Index in the compiled function table.
    int funcIdx = -1;
    /// For methods: what `Self` means in the body.
    Type selfType;
    /// For a trait default method: the trait (so `self` is bound `Self: Trait`).
    TraitInfo trait;
    /// For an impl method: the impl it belongs to.
    ImplInfo impl;
    /// Type parameters in scope in the signature and body, by name.
    Type[string] tpScope;
}

/// An impl of a user trait.
final class ImplInfo
{
    TraitInfo trait;
    int ctor;
    TypeParam[] tparams;
    Type head;
    /// One entry per trait method; null where the trait's default is used.
    FnInfo[] methods;
    ImplDecl decl;
    int module_;
}

/// A local variable: a parameter, a `let`/`var`/pattern binding or `self`.
final class LocalVar
{
    string name;
    Type type;
    bool mutable;
    /// The function (or lambda) that binds it.
    FuncCtx owner;
    /// Frame slot, assigned by the bytecode compiler.
    int slot = -1;
}

/// Per-function state shared between the checker and the compiler.
final class FuncCtx
{
    /// The enclosing function for a lambda.
    FuncCtx parent;
    /// The type `return` is checked against; null while unknown.
    Type ret;
    /// Loops open in this function while checking.
    int loopDepth;
    /// Variables of enclosing functions that this (lambda) body reads.
    LocalVar[] captures;
    /// Index in the compiled function table, assigned by the compiler.
    int funcIdx = -1;

    int captureIndex(LocalVar v) const
    {
        foreach (i, c; captures)
            if (c is v)
                return cast(int) i;
        return -1;
    }
}

unittest
{
    // unification binds variables directly and applies the occurs check
    auto a = newVar();
    auto b = newVar();
    assert(unify(mkList(a), mkList(tInt)));
    assert(typeEq(a, tInt));
    assert(!unify(mkList(b), b)); // occurs check
    assert(unify(mkFn([b], tStr), mkFn([tBool], tStr)));
    assert(typeEq(b, tBool));
    assert(!unify(tInt, tFloat));
    assert(!unify(mkTuple([tInt, tInt]), mkTuple([tInt, tInt, tInt])));
}

unittest
{
    // substitution replaces rigid parameters, and zonk resolves solved variables
    auto p = new TypeParam("T");
    auto t = mkMap(tStr, mkList(p.type));
    auto s = subst(t, [p], [tInt]);
    assert(typeStr(s) == "#[Str: [Int]]");
    auto v = newVar();
    auto l = mkList(v);
    assert(hasUnsolved(l));
    unify(v, tChar);
    assert(!hasUnsolved(l) && typeStr(zonk(l)) == "[Char]");
}
