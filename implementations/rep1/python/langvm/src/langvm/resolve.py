"""Resolving written types, trait references and qualified paths (SPEC 5.4, 6.1)."""

from __future__ import annotations

from . import syntax as S
from .diagnostics import error
from .program import Module, Program, TraitInfo
from .traits import is_key
from .types import PRIMS, TFn, TList, TMap, TNamed, TTuple, UNIT


class Scope:
    """What a written type may mention: its module, type parameters and ``Self``."""

    __slots__ = ("module", "tparams", "self_ty")

    def __init__(self, module: Module, tparams: dict, self_ty):
        self.module = module
        self.tparams = tparams
        self.self_ty = self_ty


class Resolver:
    def __init__(self, program: Program):
        self.program = program

    # ------------------------------------------------------------ modules
    def import_module(self, module: Module, qual: str, qual_pos) -> Module:
        m = module.imports.get(qual)
        if m is None:
            raise error("unknown-module", qual_pos)
        return m

    # -------------------------------------------------------------- types
    def resolve_type(self, t, scope: Scope):
        c = type(t)
        if c is S.TyName:
            return self.resolve_named(t, scope)
        if c is S.TyList:
            return TList(self.resolve_type(t.elem, scope))
        if c is S.TyMap:
            k = self.resolve_type(t.key, scope)
            v = self.resolve_type(t.value, scope)
            if not is_key(k):
                raise error("bad-key-type", t.pos)
            return TMap(k, v)
        if c is S.TyTuple:
            if len(t.items) > 8:
                raise error("bad-arity", t.pos)
            return TTuple([self.resolve_type(x, scope) for x in t.items])
        if c is S.TyFn:
            if len(t.params) > 16:
                raise error("bad-arity", t.pos)
            ps = [self.resolve_type(x, scope) for x in t.params]
            r = self.resolve_type(t.ret, scope) if t.ret is not None else UNIT
            return TFn(ps, r)
        raise AssertionError(t)

    def resolve_named(self, t: S.TyName, scope: Scope):
        nargs = 0 if t.args is None else len(t.args)
        if t.qual is not None:
            mod = self.import_module(scope.module, t.qual, t.qual_pos)
            decl = mod.types.get(t.name)
            if decl is None:
                raise error("unknown-type", t.name_pos)
            if not decl.pub and mod is not scope.module:
                raise error("not-public", t.name_pos)
            return self.apply_decl(t, decl, scope)
        name = t.name
        tp = scope.tparams.get(name)
        if tp is not None:
            if nargs:
                raise error("arity-type", t.pos)
            return tp
        if name == "Self":
            if scope.self_ty is None:
                raise error("self-outside", t.pos)
            if nargs:
                raise error("arity-type", t.pos)
            return scope.self_ty
        prim = PRIMS.get(name)
        if prim is not None:
            if nargs:
                raise error("arity-type", t.pos)
            return prim
        decl = scope.module.types.get(name)
        if decl is None:
            decl = self.program.prelude.types.get(name)
        if decl is None:
            raise error("unknown-type", t.name_pos)
        return self.apply_decl(t, decl, scope)

    def apply_decl(self, t: S.TyName, decl, scope: Scope):
        nargs = 0 if t.args is None else len(t.args)
        if nargs != len(decl.tparams):
            raise error("arity-type", t.pos)
        args = [self.resolve_type(a, scope) for a in (t.args or ())]
        return TNamed(decl, args)

    # ------------------------------------------------------------- traits
    def resolve_trait_ref(self, ref: S.TraitRef, module: Module) -> TraitInfo:
        if ref.qual is not None:
            mod = self.import_module(module, ref.qual, ref.qual_pos)
            tr = mod.traits.get(ref.name)
            if tr is None:
                raise error("unknown-trait", ref.name_pos)
            if not tr.pub and mod is not module:
                raise error("not-public", ref.name_pos)
            return tr
        tr = module.traits.get(ref.name)
        if tr is None:
            tr = self.program.prelude.traits.get(ref.name)
        if tr is None:
            raise error("unknown-trait", ref.name_pos)
        return tr

    def find_trait_by_name(self, module: Module, name: str) -> TraitInfo | None:
        """Section 5.4 rule 2: the trait a path qualifier ``name`` denotes, if any."""
        tr = module.traits.get(name)
        if tr is not None:
            return tr
        for alias in sorted(module.imports):
            m = module.imports[alias]
            if m is module:
                continue
            t = m.traits.get(name)
            if t is not None and t.pub:
                return t
        return self.program.prelude.traits.get(name)
