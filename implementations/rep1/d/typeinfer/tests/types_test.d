/// Unit tests for typeinfer.types, unify, scheme and printer.
module types_test;

import std.exception : assertThrown, collectException;
import typeinfer.errors;
import typeinfer.printer;
import typeinfer.scheme;
import typeinfer.types;
import typeinfer.unify;

private ErrorKind errorOf(TypeStore s, TypeId a, TypeId b)
{
    auto e = collectException!TypeError(unify(s, a, b));
    return e is null ? ErrorKind.none : e.kind;
}

unittest // find follows and compresses chains
{
    auto s = new TypeStore;
    auto a = s.newVar(0), b = s.newVar(0), c = s.newVar(0);
    s.nodes[a].a = b;
    s.nodes[b].a = c;
    assert(s.find(a) == c);
    assert(s.nodes[a].a == c); // path compressed
    assert(s.isUnboundVar(c));
}

unittest // unify binds variables and is symmetric
{
    auto s = new TypeStore;
    auto v = s.newVar(0);
    unify(s, v, TypeStore.intType);
    assert(s.find(v) == TypeStore.intType);
    auto w = s.newVar(0);
    unify(s, TypeStore.boolType, w);
    assert(s.find(w) == TypeStore.boolType);
}

unittest // constructor mismatches are unify errors
{
    auto s = new TypeStore;
    assert(errorOf(s, TypeStore.intType, TypeStore.boolType) == ErrorKind.unify);
    assert(errorOf(s, TypeStore.intType, s.newArrow(s.newVar(0), s.newVar(0))) == ErrorKind.unify);
    assert(errorOf(s, s.newList(TypeStore.intType), TypeStore.intType) == ErrorKind.unify);
}

unittest // tuples: arity matters, components unify pairwise
{
    auto s = new TypeStore;
    auto two = s.newTuple([TypeStore.intType, TypeStore.intType]);
    auto three = s.newTuple([TypeStore.intType, TypeStore.intType, TypeStore.intType]);
    auto nested = s.newTuple([two, TypeStore.intType]);
    assert(errorOf(s, two, three) == ErrorKind.unify);
    assert(errorOf(s, three, nested) == ErrorKind.unify);
    auto v = s.newVar(0);
    unify(s, s.newTuple([v, TypeStore.boolType]), s.newTuple([TypeStore.intType, TypeStore.boolType]));
    assert(s.find(v) == TypeStore.intType);
}

unittest // occurs check
{
    auto s = new TypeStore;
    auto v = s.newVar(0);
    assert(errorOf(s, v, s.newArrow(v, TypeStore.intType)) == ErrorKind.occurs);
    auto w = s.newVar(0);
    assert(errorOf(s, w, s.newList(s.newTuple([TypeStore.intType, w]))) == ErrorKind.occurs);
    // unifying a variable with itself is fine
    auto u = s.newVar(0);
    unify(s, u, u);
}

unittest // the occurs check is reported before later component mismatches
{
    auto s = new TypeStore;
    auto x = s.newVar(0);
    auto left = s.newTuple([x, TypeStore.intType]);
    auto right = s.newTuple([s.newList(x), TypeStore.boolType]);
    assert(errorOf(s, left, right) == ErrorKind.occurs);
}

unittest // binding lowers levels of variables in the bound type
{
    auto s = new TypeStore;
    auto outer = s.newVar(1);
    auto inner = s.newVar(5);
    unify(s, outer, s.newList(inner));
    assert(s.nodes[inner].level == 1);
}

unittest // generalize quantifies only variables deeper than the level
{
    auto s = new TypeStore;
    auto shallow = s.newVar(0), deep = s.newVar(2);
    auto t = s.newArrow(shallow, deep);
    assert(generalize(s, t, 1));
    assert(s.nodes[shallow].level == 0);
    assert(s.nodes[deep].level == genericLevel);
    assert(!generalize(s, TypeStore.intType, 0));
}

unittest // instantiate gives fresh variables, shares what is not quantified
{
    auto s = new TypeStore;
    auto a = s.newVar(genericLevel);
    auto mono = s.newVar(0);
    auto scheme = s.newArrow(a, s.newTuple([a, mono, TypeStore.intType]));
    auto i1 = instantiate(s, scheme, 1);
    auto i2 = instantiate(s, scheme, 1);
    assert(i1 != scheme && i1 != i2);
    assert(typeToString(s, i1) == "'a -> 'a * 'b * int");
    // the two copies are independent
    unify(s, s.nodes[i1].a, TypeStore.intType);
    assert(typeToString(s, i1) == "int -> int * 'a * int");
    assert(typeToString(s, i2) == "'a -> 'a * 'b * int");
    // the non-quantified variable is shared
    unify(s, mono, TypeStore.boolType);
    assert(typeToString(s, i2) == "'a -> 'a * bool * int");
}

unittest // instantiation preserves sharing and returns closed sub-terms unchanged
{
    auto s = new TypeStore;
    auto a = s.newVar(genericLevel);
    auto pair = s.newTuple([a, a]);
    auto quad = s.newTuple([pair, pair]);
    auto inst = instantiate(s, quad, 0);
    assert(s.pool[s.nodes[inst].a] == s.pool[s.nodes[inst].a + 1]);
    auto closed = s.newList(TypeStore.intType);
    assert(instantiate(s, closed, 0) == closed);
}

unittest // printing: parentheses only where required
{
    auto s = new TypeStore;
    immutable I = TypeStore.intType;
    auto fn = s.newArrow(I, I);
    assert(typeToString(s, s.newArrow(fn, I)) == "(int -> int) -> int");
    assert(typeToString(s, s.newArrow(I, fn)) == "int -> int -> int");
    assert(typeToString(s, s.newTuple([fn, s.newTuple([I, I]), I])) == "(int -> int) * (int * int) * int");
    assert(typeToString(s, s.newArrow(s.newTuple([I, I]), s.newTuple([I, I]))) == "int * int -> int * int");
    assert(typeToString(s, s.newList(s.newList(I))) == "int list list");
    assert(typeToString(s, s.newList(fn)) == "(int -> int) list");
    assert(typeToString(s, s.newList(s.newTuple([I, TypeStore.boolType]))) == "(int * bool) list");
    assert(typeToString(s, TypeStore.unitType) == "unit");
}

unittest // printing: variable names by first appearance, beyond 'z
{
    auto s = new TypeStore;
    auto a = s.newVar(0), b = s.newVar(0);
    assert(typeToString(s, s.newArrow(b, s.newArrow(a, b))) == "'a -> 'b -> 'a");
    TypeId[] vars;
    foreach (i; 0 .. 60)
        vars ~= s.newVar(0);
    auto t = s.newTuple(vars);
    auto text = typeToString(s, t);
    import std.algorithm : canFind;
    assert(text.canFind(" 'z * 'a1 * 'b1 "));
    assert(text.canFind(" 'z1 * 'a2 "));
}
