"""Pattern usefulness, exhaustiveness and irrefutability (SPEC sections 12.3-12.6)."""

from __future__ import annotations

from . import syntax as S
from .types import BOOL, TList, TNamed, TPrim, TTuple, prune, subst

# A normalised pattern is ``None`` (wildcard) or ``(key, subpatterns)``.
_TUPLE = ("tuple",)
_STRUCT = ("struct",)
_TRUE = ("lit", True)
_FALSE = ("lit", False)


def normalize(p):
    c = type(p)
    if c is S.PWild:
        return None
    if c is S.PBind:
        if p.variant is not None:
            return (("v", p.variant.uid), ())
        return None
    if c is S.PLit:
        return (("lit", p.value), ())
    if c is S.PTuple:
        return (_TUPLE, tuple(normalize(x) for x in p.items))
    if c is S.PList:
        return (("list", len(p.items), p.has_rest), tuple(normalize(x) for x in p.items))
    if c is S.PVariant:
        subs = tuple(normalize(x) for x in (p.args or ()))
        return (("v", p.variant.uid), subs)
    if c is S.PStruct:
        decl = p.decl
        subs = [None] * len(decl.fields)
        for f in p.fields:
            if f.pat is not None:
                subs[f.index] = normalize(f.pat)
        return (_STRUCT, tuple(subs))
    raise AssertionError(p)


def _constructors(ty):
    """All constructors of a finite type as ``[(key, subtypes)]``; ``None`` if infinite."""
    ty = prune(ty)
    c = type(ty)
    if c is TPrim:
        if ty is BOOL:
            return [(_TRUE, ()), (_FALSE, ())]
        if ty.name == "Unit":
            return [(("unit",), ())]
        return None
    if c is TTuple:
        return [(_TUPLE, ty.items)]
    if c is TNamed:
        decl = ty.decl
        m = dict(zip(decl.tparams, ty.args))
        if decl.is_enum:
            return [(("v", v.uid), tuple(subst(p, m) for p in v.payload)) for v in decl.variants]
        return [(_STRUCT, tuple(subst(f, m) for _, f in decl.fields))]
    return None


def _subtypes(ty, key):
    cs = _constructors(ty)
    if cs is not None:
        for k, subs in cs:
            if k == key:
                return subs
    return ()


def _specialize(rows, key, arity):
    out = []
    pad = (None,) * arity
    for r in rows:
        p = r[0]
        if p is None:
            out.append(pad + r[1:])
        elif p[0] == key:
            out.append(p[1] + r[1:])
    return out


def useful(rows, q, types) -> bool:
    """``U(rows, q)``: is ``q`` useful against the matrix ``rows``?"""
    if not q:
        return not rows
    ty = prune(types[0])
    if type(ty) is TList:
        return _useful_list(rows, q, ty, types)
    first = q[0]
    if first is not None:
        key, subs = first
        sub_types = _subtypes(ty, key)
        return useful(_specialize(rows, key, len(subs)), subs + q[1:], tuple(sub_types) + types[1:])
    used = {r[0][0] for r in rows if r[0] is not None}
    ctors = _constructors(ty)
    if ctors is not None and all(k in used for k, _ in ctors):
        for key, sub_types in ctors:
            n = len(sub_types)
            if useful(_specialize(rows, key, n), (None,) * n + q[1:], tuple(sub_types) + types[1:]):
                return True
        return False
    return useful([r[1:] for r in rows if r[0] is None], q[1:], types[1:])


def _useful_list(rows, q, ty, types) -> bool:
    elem = ty.elem
    lmax = 0
    for r in rows:
        p = r[0]
        if p is not None and p[0][0] == "list":
            lmax = max(lmax, p[0][1])
    qp = q[0]
    if qp is not None:
        lmax = max(lmax, qp[0][1])
    for k in range(lmax + 2):
        if qp is not None:
            _, n, opn = qp[0]
            if not (k >= n if opn else k == n):
                continue
            qrow = qp[1] + (None,) * (k - n) + q[1:]
        else:
            qrow = (None,) * k + q[1:]
        new_rows = []
        for r in rows:
            p = r[0]
            if p is None:
                new_rows.append((None,) * k + r[1:])
            else:
                _, n, opn = p[0]
                if (k >= n) if opn else (k == n):
                    new_rows.append(p[1] + (None,) * (k - n) + r[1:])
        if useful(new_rows, qrow, (elem,) * k + types[1:]):
            return True
    return False


def is_exhaustive(arms, scrut_ty) -> bool:
    rows = [(normalize(a.pat),) for a in arms if a.guard is None]
    return not useful(rows, (None,), (scrut_ty,))


def first_unreachable(arms, scrut_ty):
    """The first arm covered by earlier unguarded arms, or ``None``."""
    rows = []
    for a in arms:
        q = (normalize(a.pat),)
        if not useful(rows, q, (scrut_ty,)):
            return a
        if a.guard is None:
            rows.append(q)
    return None


def irrefutable(p) -> bool:
    c = type(p)
    if c is S.PWild:
        return True
    if c is S.PBind:
        return p.variant is None or len(p.variant.enum.variants) == 1
    if c is S.PTuple:
        return all(irrefutable(x) for x in p.items)
    if c is S.PStruct:
        return all(f.pat is None or irrefutable(f.pat) for f in p.fields)
    if c is S.PVariant:
        return len(p.variant.enum.variants) == 1 and all(irrefutable(x) for x in (p.args or ()))
    if c is S.PList:
        return p.has_rest and not p.items
    return False
