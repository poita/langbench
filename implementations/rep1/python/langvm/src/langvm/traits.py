"""Trait satisfaction: the built-in Eq/Ord/Key rules (section 7) and user impls (section 8.4)."""

from __future__ import annotations

from .program import EQ_TRAIT, KEY_TRAIT, ORD_TRAIT, Program, head_key_of
from .types import (
    BOOL, CHAR, FLOAT, INT, STR, TFn, TList, TMap, TNamed, TParam, TPrim, TTuple, TVar,
    prune, subst,
)

_KEY_PRIMS = (INT, BOOL, CHAR, STR)
_ORD_PRIMS = (INT, FLOAT, BOOL, CHAR, STR)


def is_key(ty) -> bool:
    ty = prune(ty)
    if type(ty) is TPrim:
        return ty in _KEY_PRIMS
    if type(ty) is TParam:
        return KEY_TRAIT in ty.bounds
    return False


def is_ord(ty) -> bool:
    ty = prune(ty)
    if type(ty) is TPrim:
        return ty in _ORD_PRIMS
    if type(ty) is TParam:
        return ORD_TRAIT in ty.bounds
    return False


def is_eq(ty, assumed: set | None = None) -> bool:
    ty = prune(ty)
    c = type(ty)
    if c is TPrim:
        return True
    if c is TList:
        return is_eq(ty.elem, assumed)
    if c is TMap:
        return is_eq(ty.val, assumed)
    if c is TTuple:
        return all(is_eq(x, assumed) for x in ty.items)
    if c is TFn:
        return False
    if c is TParam:
        return EQ_TRAIT in ty.bounds or KEY_TRAIT in ty.bounds
    if c is TNamed:
        decl = ty.decl
        if assumed is None:
            assumed = set()
        if decl.uid in assumed:
            return True
        assumed.add(decl.uid)
        m = dict(zip(decl.tparams, ty.args))
        if decl.is_enum:
            ok = all(is_eq(subst(p, m), assumed) for v in decl.variants for p in v.payload)
        else:
            ok = all(is_eq(subst(f, m), assumed) for _, f in decl.fields)
        assumed.discard(decl.uid)
        return ok
    return True  # unsolved variable: not decidable here


def _match_head(head, ty, binding: dict) -> None:
    """Bind the impl's parameters by matching its head against ``ty``."""
    ty = prune(ty)
    c = type(head)
    if c is TParam:
        binding[head] = ty
    elif c is TList:
        _match_head(head.elem, ty.elem, binding)
    elif c is TMap:
        _match_head(head.key, ty.key, binding)
        _match_head(head.val, ty.val, binding)
    elif c is TNamed:
        for h, a in zip(head.args, ty.args):
            _match_head(h, a, binding)


def holds(program: Program, ty, trait) -> bool:
    """Does ``ty`` satisfy ``trait`` (built-in or user)?"""
    if trait is EQ_TRAIT:
        return is_eq(ty)
    if trait is ORD_TRAIT:
        return is_ord(ty)
    if trait is KEY_TRAIT:
        return is_key(ty)
    ty = prune(ty)
    if type(ty) is TParam:
        return trait in ty.bounds
    if type(ty) is TVar:
        return False
    hk = head_key_of(ty)
    if hk is None:
        return False
    impl = program.impls.get((trait.uid, hk))
    if impl is None:
        return False
    if impl.tparams:
        binding: dict = {}
        _match_head(impl.head, ty, binding)
        for p in impl.tparams:
            arg = binding.get(p)
            if arg is None:
                continue
            for b in p.bounds:
                if not holds(program, arg, b):
                    return False
    return True
