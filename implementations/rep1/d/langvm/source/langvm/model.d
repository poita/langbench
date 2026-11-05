/// The semantic model: types, declarations, modules and local variables.
module langvm.model;

import langvm.ast;
import langvm.diag;

/// Kinds of semantic types.
enum TK : ubyte
{
    int_, float_, bool_, char_, str, unit, list, map, tuple, fn, named, param, var,
}

/// A rigid generic parameter (of a function, impl, or the `Self` of a trait).
final class TypeParam
{
    /// Name as written.
    string name;
    /// Declared bounds (built-in traits and user traits).
    TraitDecl[] bounds;
    /// Position of the name token.
    Pos pos;

    this(string name, Pos pos = Pos.init)
    {
        this.name = name;
        this.pos = pos;
    }

    /// True if one of the declared bounds is `t`.
    bool hasBound(const TraitDecl t) const
    {
        foreach (b; bounds)
            if (b is t)
                return true;
        return false;
    }
}

/// A semantic type.
final class Type
{
    /// The form of the type.
    TK k;
    /// Component types: list `[elem]`; map `[key, value]`; tuple components;
    /// function parameters followed by the return type; named: type arguments.
    Type[] args;
    /// The declaration for `named` types.
    DataDecl decl;
    /// The parameter for `param` types.
    TypeParam tp;
    /// For inference variables: the type it was solved to (null when unsolved).
    Type link;
    /// Identity of an inference variable (debugging).
    int id;

    this(TK k, Type[] args = null)
    {
        this.k = k;
        this.args = args;
    }
}

/// Primitive type singletons.
__gshared Type tInt = new Type(TK.int_);
/// ditto
__gshared Type tFloat = new Type(TK.float_);
/// ditto
__gshared Type tBool = new Type(TK.bool_);
/// ditto
__gshared Type tChar = new Type(TK.char_);
/// ditto
__gshared Type tStr = new Type(TK.str);
/// ditto
__gshared Type tUnit = new Type(TK.unit);

/// Creates a list type.
Type listOf(Type e)
{
    return new Type(TK.list, [e]);
}

/// Creates a map type.
Type mapOf(Type k, Type v)
{
    return new Type(TK.map, [k, v]);
}

/// Creates a named type.
Type namedOf(DataDecl d, Type[] args)
{
    auto t = new Type(TK.named, args);
    t.decl = d;
    return t;
}

/// Creates a parameter type.
Type paramOf(TypeParam p)
{
    auto t = new Type(TK.param);
    t.tp = p;
    return t;
}

/// Creates a function type from parameter types and a return type.
Type fnOf(Type[] params, Type ret)
{
    return new Type(TK.fn, params ~ ret);
}

/// Parameter types of a function type.
Type[] fnParams(Type t)
{
    return t.args[0 .. $ - 1];
}

/// Return type of a function type.
Type fnRet(Type t)
{
    return t.args[$ - 1];
}

private __gshared int varCounter = 0;

/// Creates a fresh inference variable.
Type freshVar()
{
    auto t = new Type(TK.var);
    t.id = ++varCounter;
    return t;
}

/// Follows the solved links of inference variables.
Type prune(Type t)
{
    while (t.k == TK.var && t.link !is null)
        t = t.link;
    return t;
}

/// Fully substitutes solved variables (the result shares unchanged subtrees).
Type zonk(Type t)
{
    t = prune(t);
    if (t.args.length == 0)
        return t;
    Type[] na = null;
    foreach (i, a; t.args)
    {
        auto z = zonk(a);
        if (z !is a && na is null)
            na = t.args.dup;
        if (na !is null)
            na[i] = z;
    }
    if (na is null)
        return t;
    auto r = new Type(t.k, na);
    r.decl = t.decl;
    return r;
}

/// True if `t` contains no unsolved variable.
bool isGround(Type t)
{
    t = prune(t);
    if (t.k == TK.var)
        return false;
    foreach (a; t.args)
        if (!isGround(a))
            return false;
    return true;
}

/// True if variable `v` (unsolved) occurs inside `t`.
bool occurs(Type v, Type t)
{
    t = prune(t);
    if (t is v)
        return true;
    foreach (a; t.args)
        if (occurs(v, a))
            return true;
    return false;
}

/// Structural equality of (ground) types.
bool typeEq(Type a, Type b)
{
    a = prune(a);
    b = prune(b);
    if (a is b)
        return true;
    if (a.k != b.k)
        return false;
    switch (a.k)
    {
    case TK.named:
        if (a.decl !is b.decl)
            return false;
        break;
    case TK.param:
        return a.tp is b.tp;
    case TK.var:
        return false;
    default:
        break;
    }
    if (a.args.length != b.args.length)
        return false;
    foreach (i; 0 .. a.args.length)
        if (!typeEq(a.args[i], b.args[i]))
            return false;
    return true;
}

/// Substitutes type parameters `from` by `to` in `t`.
Type subst(Type t, const(TypeParam)[] from, Type[] to)
{
    if (from.length == 0)
        return t;
    t = prune(t);
    if (t.k == TK.param)
    {
        foreach (i, p; from)
            if (p is t.tp)
                return to[i];
        return t;
    }
    if (t.args.length == 0)
        return t;
    Type[] na = null;
    foreach (i, a; t.args)
    {
        auto z = subst(a, from, to);
        if (z !is a && na is null)
            na = t.args.dup;
        if (na !is null)
            na[i] = z;
    }
    if (na is null)
        return t;
    auto r = new Type(t.k, na);
    r.decl = t.decl;
    return r;
}

/// Renders a type for debugging and test output.
string typeStr(Type t)
{
    import std.array : join;
    import std.algorithm : map;
    import std.conv : to;

    t = prune(t);
    final switch (t.k)
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
        return "(" ~ t.args.map!(a => typeStr(a)).join(", ") ~ ")";
    case TK.fn:
        return "fn(" ~ fnParams(t).map!(a => typeStr(a)).join(", ") ~ ") -> " ~ typeStr(fnRet(t));
    case TK.named:
        return t.decl.name ~ (t.args.length ? "<" ~ t.args.map!(a => typeStr(a)).join(", ") ~ ">" : "");
    case TK.param:
        return t.tp.name;
    case TK.var:
        return "?" ~ t.id.to!string;
    }
}

/// Head-constructor ids: primitives and containers.
enum HeadCtor : int
{
    int_ = 0, float_, bool_, char_, str, unit, list, map, firstData,
}

/// Which built-in trait (if any) a [TraitDecl] is.
enum BuiltinTrait : ubyte
{
    none, eq, ord, key,
}

/// A field of a struct.
struct FieldDecl
{
    string name;
    Pos pos;
    TypeExpr te;
    Type ty;
}

/// A variant of an enum.
final class VariantDecl
{
    string name;
    Pos pos;
    TypeExpr[] tes;
    Type[] payload;
}

/// A struct or enum declaration.
final class DataDecl
{
    string name;
    ModuleDecl mod;
    bool isEnum;
    bool pub;
    /// Global dense id (also determines the head constructor id).
    int id;
    Pos pos;
    TypeParam[] tparams;
    FieldDecl[] fields;
    VariantDecl[] variants;
    /// Index of a field by name or -1.
    int fieldIndex(string n) const
    {
        foreach (i, f; fields)
            if (f.name == n)
                return cast(int) i;
        return -1;
    }

    /// Index of a variant by name or -1.
    int variantIndex(string n) const
    {
        foreach (i, v; variants)
            if (v.name == n)
                return cast(int) i;
        return -1;
    }

    /// The head constructor id of values of this declaration.
    int headCtor() const
    {
        return HeadCtor.firstData + id;
    }
}

/// A method declared by a trait.
final class MethodDecl
{
    string name;
    Pos pos;
    Pos fnPos;
    MethodAst ast;
    Type[] paramTypes;
    Type ret;
    bool hasDefault;
    /// The function holding the default body (if any).
    FuncDecl defaultFn;
}

/// A trait declaration (user-declared or one of the three built-in traits).
final class TraitDecl
{
    string name;
    ModuleDecl mod;
    bool pub;
    BuiltinTrait builtin;
    /// Global dense id.
    int id;
    Pos pos;
    MethodDecl[] methods;
    /// `Self` as a rigid parameter, with this trait as its only bound.
    TypeParam selfParam;

    int methodIndex(string n) const
    {
        foreach (i, m; methods)
            if (m.name == n)
                return cast(int) i;
        return -1;
    }
}

/// How a function declaration appears in source.
enum FuncKind : ubyte
{
    free, traitDefault, implMethod,
}

/// A user function, impl method, or trait default method.
final class FuncDecl
{
    string name;
    ModuleDecl mod;
    bool pub;
    FuncKind kind;
    Pos pos; // `fn` keyword
    Pos namePos;
    TypeParam[] tparams;
    string[] paramNames;
    Pos[] paramPos;
    Type[] paramTypes;
    Type ret;
    Block body;
    /// Type of `self` for methods (null for free functions).
    Type selfType;
    TraitDecl trait; // for traitDefault / implMethod
    ImplDecl impl; // for implMethod
    /// Index into the program's function table.
    int index = -1;
    FuncInfo info;
    /// The `self` variable of methods (set by the checker).
    LocalVar selfVar;
    /// Parameter variables (set by the checker).
    LocalVar[] paramVars;
    bool signatureResolved;
}

/// An impl declaration.
final class ImplDecl
{
    ModuleDecl mod;
    ImplAst ast;
    Pos pos;
    TraitDecl trait;
    TypeParam[] tparams;
    Type head;
    int headCtor = -1;
    FuncDecl[] methods; // as written
    /// For each trait method index: the implementing function (null = use default).
    FuncDecl[] byIndex;
}

/// What a name in a module's values namespace denotes.
final class ValueItem
{
    enum Kind : ubyte
    {
        func, variant, builtin,
    }

    Kind kind;
    bool pub;
    Pos pos;
    FuncDecl fn;
    DataDecl enumDecl;
    int variantIdx;
    Builtin builtin;
}

/// A module of the program.
final class ModuleDecl
{
    string name;
    int index;
    ModuleAst ast;
    DataDecl[string] types;
    TraitDecl[string] traits;
    ValueItem[string] values;
    ModuleDecl[string] imports;
    /// Imports sorted by bound name (filled after pass 3.2).
    string[] importOrder;
    bool isPrelude;
}

/// A built-in function.
final class Builtin
{
    string name;
    int index;
    string sig;
    TypeParam[] tparams;
    Type[] paramTypes;
    Type ret;
}

/// A local variable (including parameters, pattern bindings and `self`).
final class LocalVar
{
    string name;
    Type ty;
    bool mutable;
    FuncInfo owner;
    Pos pos;
    /// Frame slot, assigned by the bytecode compiler.
    int slot = -1;
}

/// Per-function information shared by the checker and the compiler.
final class FuncInfo
{
    FuncInfo parent;
    /// Variables captured from enclosing functions, in order of first use.
    LocalVar[] captures;
    /// Function table index (assigned for lambdas by the compiler, for declarations earlier).
    int index = -1;

    int captureIndex(LocalVar v)
    {
        foreach (i, c; captures)
            if (c is v)
                return cast(int) i;
        return -1;
    }
}
