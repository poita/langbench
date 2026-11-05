"""Semantic types, unification and the structural built-in traits.

A type is one of the classes below.  `TVar` is an inference variable created by
a generic call; `TParam` is a rigid generic parameter of the declaration whose
body is being checked.
"""


class Ty:
    __slots__ = ()


class TPrim(Ty):
    __slots__ = ('name',)

    def __init__(self, name):
        self.name = name


class TList(Ty):
    __slots__ = ('elem',)

    def __init__(self, elem):
        self.elem = elem


class TMap(Ty):
    __slots__ = ('key', 'val')

    def __init__(self, key, val):
        self.key = key
        self.val = val


class TTuple(Ty):
    __slots__ = ('parts',)

    def __init__(self, parts):
        self.parts = tuple(parts)


class TFn(Ty):
    __slots__ = ('params', 'ret')

    def __init__(self, params, ret):
        self.params = tuple(params)
        self.ret = ret


class TNamed(Ty):
    __slots__ = ('decl', 'args')

    def __init__(self, decl, args):
        self.decl = decl
        self.args = tuple(args)


class TParam(Ty):
    """A rigid generic parameter.  `bounds` holds 'Eq'/'Ord'/'Key' strings and
    TraitDecl objects."""
    __slots__ = ('name', 'bounds')

    def __init__(self, name, bounds=()):
        self.name = name
        self.bounds = list(bounds)


class TVar(Ty):
    __slots__ = ('sol',)

    def __init__(self):
        self.sol = None


T_INT = TPrim('Int')
T_FLOAT = TPrim('Float')
T_BOOL = TPrim('Bool')
T_CHAR = TPrim('Char')
T_STR = TPrim('Str')
T_UNIT = TPrim('Unit')

PRIM_BY_NAME = {
    'Int': T_INT, 'Float': T_FLOAT, 'Bool': T_BOOL,
    'Char': T_CHAR, 'Str': T_STR, 'Unit': T_UNIT,
}
PRIM_NAMES = ('Int', 'Float', 'Bool', 'Char', 'Str', 'Unit')
RESERVED_TYPE_NAMES = ('Int', 'Float', 'Bool', 'Char', 'Str', 'Unit', 'Self')


def prune(t):
    """Follow solved inference variables one level deep."""
    while type(t) is TVar and t.sol is not None:
        t = t.sol
    return t


def resolve(t):
    """Substitute every solved variable throughout `t`."""
    t = prune(t)
    k = type(t)
    if k is TList:
        return TList(resolve(t.elem))
    if k is TMap:
        return TMap(resolve(t.key), resolve(t.val))
    if k is TTuple:
        return TTuple([resolve(p) for p in t.parts])
    if k is TFn:
        return TFn([resolve(p) for p in t.params], resolve(t.ret))
    if k is TNamed:
        return TNamed(t.decl, [resolve(a) for a in t.args])
    return t


def is_ground(t):
    t = prune(t)
    k = type(t)
    if k is TVar:
        return False
    if k is TList:
        return is_ground(t.elem)
    if k is TMap:
        return is_ground(t.key) and is_ground(t.val)
    if k is TTuple:
        return all(is_ground(p) for p in t.parts)
    if k is TFn:
        return all(is_ground(p) for p in t.params) and is_ground(t.ret)
    if k is TNamed:
        return all(is_ground(a) for a in t.args)
    return True


def occurs(v, t):
    t = prune(t)
    if t is v:
        return True
    k = type(t)
    if k is TList:
        return occurs(v, t.elem)
    if k is TMap:
        return occurs(v, t.key) or occurs(v, t.val)
    if k is TTuple:
        return any(occurs(v, p) for p in t.parts)
    if k is TFn:
        return any(occurs(v, p) for p in t.params) or occurs(v, t.ret)
    if k is TNamed:
        return any(occurs(v, a) for a in t.args)
    return False


def unify(a, b):
    """Solve variables so that `a` and `b` become equal; False on failure."""
    a = prune(a)
    b = prune(b)
    if a is b:
        return True
    if type(a) is TVar:
        if occurs(a, b):
            return False
        a.sol = b
        return True
    if type(b) is TVar:
        if occurs(b, a):
            return False
        b.sol = a
        return True
    ka = type(a)
    if ka is not type(b):
        return False
    if ka is TPrim:
        return a.name == b.name
    if ka is TList:
        return unify(a.elem, b.elem)
    if ka is TMap:
        return unify(a.key, b.key) and unify(a.val, b.val)
    if ka is TTuple:
        if len(a.parts) != len(b.parts):
            return False
        for x, y in zip(a.parts, b.parts):
            if not unify(x, y):
                return False
        return True
    if ka is TFn:
        if len(a.params) != len(b.params):
            return False
        for x, y in zip(a.params, b.params):
            if not unify(x, y):
                return False
        return unify(a.ret, b.ret)
    if ka is TNamed:
        if a.decl is not b.decl or len(a.args) != len(b.args):
            return False
        for x, y in zip(a.args, b.args):
            if not unify(x, y):
                return False
        return True
    return False


def type_eq(a, b):
    """Equality of types, with rigid parameters equal only to themselves."""
    a = prune(a)
    b = prune(b)
    if a is b:
        return True
    ka = type(a)
    if ka is not type(b):
        return False
    if ka is TPrim:
        return a.name == b.name
    if ka is TList:
        return type_eq(a.elem, b.elem)
    if ka is TMap:
        return type_eq(a.key, b.key) and type_eq(a.val, b.val)
    if ka is TTuple:
        return len(a.parts) == len(b.parts) and all(
            type_eq(x, y) for x, y in zip(a.parts, b.parts))
    if ka is TFn:
        return (len(a.params) == len(b.params)
                and all(type_eq(x, y) for x, y in zip(a.params, b.params))
                and type_eq(a.ret, b.ret))
    if ka is TNamed:
        return a.decl is b.decl and all(
            type_eq(x, y) for x, y in zip(a.args, b.args))
    return False


def subst(t, mapping):
    """Replace rigid parameters by types; `mapping` is keyed by TParam."""
    if not mapping:
        return t
    t = prune(t)
    k = type(t)
    if k is TParam:
        return mapping.get(t, t)
    if k is TList:
        return TList(subst(t.elem, mapping))
    if k is TMap:
        return TMap(subst(t.key, mapping), subst(t.val, mapping))
    if k is TTuple:
        return TTuple([subst(p, mapping) for p in t.parts])
    if k is TFn:
        return TFn([subst(p, mapping) for p in t.params], subst(t.ret, mapping))
    if k is TNamed:
        return TNamed(t.decl, [subst(a, mapping) for a in t.args])
    return t


def head_ctor(t):
    """The head constructor used for impl lookup, or None."""
    t = prune(t)
    k = type(t)
    if k is TPrim:
        return t.name
    if k is TList:
        return 'List'
    if k is TMap:
        return 'Map'
    if k is TNamed:
        return t.decl
    return None


# --- the built-in traits ----------------------------------------------------

def holds_eq(t, assume=None):
    """Structural `Eq`, with a coinductive assumption set of declarations."""
    t = prune(t)
    k = type(t)
    if k is TPrim:
        return True
    if k is TList:
        return holds_eq(t.elem, assume)
    if k is TMap:
        return holds_eq(t.val, assume)
    if k is TTuple:
        return all(holds_eq(p, assume) for p in t.parts)
    if k is TFn:
        return False
    if k is TParam:
        return 'Eq' in t.bounds or 'Key' in t.bounds
    if k is TNamed:
        if assume is None:
            assume = set()
        if id(t.decl) in assume:
            return True
        assume = assume | {id(t.decl)}
        mapping = dict(zip(t.decl.params, t.args))
        for ft in t.decl.member_types():
            if not holds_eq(subst(ft, mapping), assume):
                return False
        return True
    return False


def holds_ord(t):
    t = prune(t)
    k = type(t)
    if k is TPrim:
        return t.name in ('Int', 'Float', 'Bool', 'Char', 'Str')
    if k is TParam:
        return 'Ord' in t.bounds
    return False


def holds_key(t):
    t = prune(t)
    k = type(t)
    if k is TPrim:
        return t.name in ('Int', 'Bool', 'Char', 'Str')
    if k is TParam:
        return 'Key' in t.bounds
    return False
