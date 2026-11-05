"""Runtime value representation.

`Int` is a Python int kept in the signed 64-bit range, `Float` a Python float,
`Bool` a Python bool, `Str` a Python str, `Char` a one-character `VChar` (a str
subclass, so that a Char is still distinguishable from a Str at run time),
`[T]` a Python list and `#[K: V]` a Python dict (which preserves insertion
order, keeps a re-assigned key in place and moves a deleted-then-reinserted key
to the end, exactly as the language requires).
"""


class VChar(str):
    __slots__ = ()


class UnitType:
    __slots__ = ()

    def __repr__(self):
        return 'unit'


UNIT = UnitType()


class StructVal:
    __slots__ = ('decl', 'fields')

    def __init__(self, decl, fields):
        self.decl = decl
        self.fields = fields


class EnumVal:
    __slots__ = ('decl', 'variant', 'payload')

    def __init__(self, decl, variant, payload):
        self.decl = decl
        self.variant = variant
        self.payload = payload


class Closure:
    __slots__ = ('func', 'upvals')

    def __init__(self, func, upvals):
        self.func = func
        self.upvals = upvals


SCALARS = (int, float, str, bool, VChar)


def vals_equal(a, b):
    """Structural equality (section 10.4)."""
    ta = type(a)
    if ta is int or ta is str or ta is VChar or ta is float or ta is bool:
        return a == b
    if ta is list:
        if len(a) != len(b):
            return False
        for x, y in zip(a, b):
            if not vals_equal(x, y):
                return False
        return True
    if ta is dict:
        if len(a) != len(b):
            return False
        for k, v in a.items():
            if k not in b or not vals_equal(v, b[k]):
                return False
        return True
    if ta is StructVal:
        for x, y in zip(a.fields, b.fields):
            if not vals_equal(x, y):
                return False
        return True
    if ta is EnumVal:
        if a.variant != b.variant:
            return False
        for x, y in zip(a.payload, b.payload):
            if not vals_equal(x, y):
                return False
        return True
    if ta is tuple:
        for x, y in zip(a, b):
            if not vals_equal(x, y):
                return False
        return True
    return a is b


def value_ctor(v):
    """The head constructor of a value, for method dispatch."""
    t = type(v)
    if t is bool:
        return 'Bool'
    if t is int:
        return 'Int'
    if t is float:
        return 'Float'
    if t is VChar:
        return 'Char'
    if t is str:
        return 'Str'
    if t is list:
        return 'List'
    if t is dict:
        return 'Map'
    if t is StructVal or t is EnumVal:
        return v.decl
    if t is UnitType:
        return 'Unit'
    return None
