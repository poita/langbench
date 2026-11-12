"""Semantic types, inference variables and unification (SPEC sections 6 and 9)."""

from __future__ import annotations


class Type:
    __slots__ = ()


class TPrim(Type):
    """A primitive type; the six instances below are the only ones."""

    __slots__ = ("name",)

    def __init__(self, name: str):
        self.name = name

    def __repr__(self):
        return self.name


INT = TPrim("Int")
FLOAT = TPrim("Float")
BOOL = TPrim("Bool")
CHAR = TPrim("Char")
STR = TPrim("Str")
UNIT = TPrim("Unit")
PRIMS = {t.name: t for t in (INT, FLOAT, BOOL, CHAR, STR, UNIT)}


class TList(Type):
    __slots__ = ("elem",)

    def __init__(self, elem: Type):
        self.elem = elem

    def __repr__(self):
        return f"[{self.elem!r}]"


class TMap(Type):
    __slots__ = ("key", "val")

    def __init__(self, key: Type, val: Type):
        self.key = key
        self.val = val

    def __repr__(self):
        return f"#[{self.key!r}: {self.val!r}]"


class TTuple(Type):
    __slots__ = ("items",)

    def __init__(self, items):
        self.items = tuple(items)

    def __repr__(self):
        return "(" + ", ".join(map(repr, self.items)) + ")"


class TFn(Type):
    __slots__ = ("params", "ret")

    def __init__(self, params, ret: Type):
        self.params = tuple(params)
        self.ret = ret

    def __repr__(self):
        return "fn(" + ", ".join(map(repr, self.params)) + f") -> {self.ret!r}"


class TNamed(Type):
    """A struct or enum applied to type arguments."""

    __slots__ = ("decl", "args")

    def __init__(self, decl, args=()):
        self.decl = decl
        self.args = tuple(args)

    def __repr__(self):
        if not self.args:
            return self.decl.name
        return self.decl.name + "<" + ", ".join(map(repr, self.args)) + ">"


class TParam(Type):
    """A rigid generic parameter (identity-compared)."""

    __slots__ = ("name", "bounds")

    def __init__(self, name: str, bounds=None):
        self.name = name
        self.bounds = bounds if bounds is not None else []

    def __repr__(self):
        return self.name


class TVar(Type):
    """An inference variable; ``ref`` is its solution once solved."""

    __slots__ = ("ref",)

    def __init__(self):
        self.ref = None

    def __repr__(self):
        return "?" if self.ref is None else repr(self.ref)


def prune(t: Type) -> Type:
    """Follow solved variables until a non-variable or an unsolved variable."""
    while type(t) is TVar and t.ref is not None:
        t = t.ref
    return t


def zonk(t: Type) -> Type:
    """Replace every solved variable by its solution, deeply."""
    t = prune(t)
    c = type(t)
    if c is TList:
        return TList(zonk(t.elem))
    if c is TMap:
        return TMap(zonk(t.key), zonk(t.val))
    if c is TTuple:
        return TTuple([zonk(x) for x in t.items])
    if c is TFn:
        return TFn([zonk(x) for x in t.params], zonk(t.ret))
    if c is TNamed:
        return TNamed(t.decl, [zonk(x) for x in t.args]) if t.args else t
    return t


def occurs(v: TVar, t: Type) -> bool:
    t = prune(t)
    if t is v:
        return True
    c = type(t)
    if c is TList:
        return occurs(v, t.elem)
    if c is TMap:
        return occurs(v, t.key) or occurs(v, t.val)
    if c is TTuple:
        return any(occurs(v, x) for x in t.items)
    if c is TFn:
        return any(occurs(v, x) for x in t.params) or occurs(v, t.ret)
    if c is TNamed:
        return any(occurs(v, x) for x in t.args)
    return False


def unify(a: Type, b: Type) -> bool:
    """Unify two types, binding variables; ``False`` on a mismatch."""
    a = prune(a)
    b = prune(b)
    if a is b:
        return True
    if type(a) is TVar:
        if occurs(a, b):
            return False
        a.ref = b
        return True
    if type(b) is TVar:
        if occurs(b, a):
            return False
        b.ref = a
        return True
    ca = type(a)
    if ca is not type(b):
        return False
    if ca is TList:
        return unify(a.elem, b.elem)
    if ca is TMap:
        return unify(a.key, b.key) and unify(a.val, b.val)
    if ca is TTuple:
        return len(a.items) == len(b.items) and all(unify(x, y) for x, y in zip(a.items, b.items))
    if ca is TFn:
        return (
            len(a.params) == len(b.params)
            and all(unify(x, y) for x, y in zip(a.params, b.params))
            and unify(a.ret, b.ret)
        )
    if ca is TNamed:
        return (
            a.decl is b.decl
            and len(a.args) == len(b.args)
            and all(unify(x, y) for x, y in zip(a.args, b.args))
        )
    return False


def type_equal(a: Type, b: Type) -> bool:
    """Structural equality of two (ground) types."""
    a = prune(a)
    b = prune(b)
    if a is b:
        return True
    ca = type(a)
    if ca is not type(b):
        return False
    if ca is TList:
        return type_equal(a.elem, b.elem)
    if ca is TMap:
        return type_equal(a.key, b.key) and type_equal(a.val, b.val)
    if ca is TTuple:
        return len(a.items) == len(b.items) and all(type_equal(x, y) for x, y in zip(a.items, b.items))
    if ca is TFn:
        return (
            len(a.params) == len(b.params)
            and all(type_equal(x, y) for x, y in zip(a.params, b.params))
            and type_equal(a.ret, b.ret)
        )
    if ca is TNamed:
        return (
            a.decl is b.decl
            and len(a.args) == len(b.args)
            and all(type_equal(x, y) for x, y in zip(a.args, b.args))
        )
    return False


def subst(t: Type, m: dict) -> Type:
    """Substitute rigid parameters according to ``m`` (TParam -> Type)."""
    c = type(t)
    if c is TParam:
        return m.get(t, t)
    if c is TPrim:
        return t
    if c is TVar:
        p = prune(t)
        return subst(p, m) if p is not t else t
    if c is TList:
        return TList(subst(t.elem, m))
    if c is TMap:
        return TMap(subst(t.key, m), subst(t.val, m))
    if c is TTuple:
        return TTuple([subst(x, m) for x in t.items])
    if c is TFn:
        return TFn([subst(x, m) for x in t.params], subst(t.ret, m))
    if c is TNamed:
        return TNamed(t.decl, [subst(x, m) for x in t.args]) if t.args else t
    return t


def contains_var(t: Type) -> bool:
    t = prune(t)
    c = type(t)
    if c is TVar:
        return True
    if c is TList:
        return contains_var(t.elem)
    if c is TMap:
        return contains_var(t.key) or contains_var(t.val)
    if c is TTuple:
        return any(contains_var(x) for x in t.items)
    if c is TFn:
        return any(contains_var(x) for x in t.params) or contains_var(t.ret)
    if c is TNamed:
        return any(contains_var(x) for x in t.args)
    return False
