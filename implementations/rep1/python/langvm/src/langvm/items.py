"""Item passes 3.1-3.6 (SPEC section 13.2): declarations, imports, signatures, impls."""

from __future__ import annotations

from . import syntax as S
from .diagnostics import error
from .prelude import install_builtins, make_prelude
from .program import (
    EQ_TRAIT, KEY_TRAIT, ORD_TRAIT, EnumInfo, FuncInfo, ImplInfo, MethodSig, Module,
    Program, StructInfo, TraitInfo, VariantInfo, head_key_of,
)
from .resolve import Resolver, Scope
from .types import UNIT, TList, TMap, TNamed, TParam, TPrim, subst, type_equal

RESERVED = frozenset(("Int", "Float", "Bool", "Char", "Str", "Unit", "Self"))


def _tparams(node_params) -> list[TParam]:
    return [TParam(g.name) for g in node_params]


def build_program(parsed: list[tuple[str, object, list]]) -> tuple[Program, Resolver]:
    """Run item passes over ``parsed`` = [(name, source_module, items)]."""
    program = Program()
    resolver = Resolver(program)
    make_prelude(program)
    install_builtins(program, resolver)
    for name, src, items in parsed:
        m = Module(name, items, src)
        program.modules.append(m)
        program.module_by_name[name] = m
    for m in program.modules:
        declare(program, m)
    for m in program.modules:
        imports(program, m)
    for m in program.modules:
        internal_dups(m)
    for m in program.modules:
        signatures(program, resolver, m)
    for m in program.modules:
        impls(program, resolver, m)
    entry_point(program)
    return program, resolver


# ------------------------------------------------------------------ 3.1 ----
def declare(program: Program, m: Module) -> None:
    for item in m.items:
        c = type(item)
        if c is S.Use:
            continue
        if c is S.ImplDecl:
            m.decls[id(item)] = ImplInfo(m, item)
            continue
        if c in (S.StructDecl, S.EnumDecl, S.TraitDecl) and item.name in RESERVED:
            raise error("reserved-name", item.name_pos)
        if c is S.StructDecl:
            info = StructInfo(program.uids.next(), m, item.name, item.pub, item)
            info.tparams = _tparams(item.tparams)
            _enter(m.types, item.name, info, item.name_pos)
            program.structs.append(info)
        elif c is S.EnumDecl:
            info = EnumInfo(program.uids.next(), m, item.name, item.pub, item)
            info.tparams = _tparams(item.tparams)
            _enter(m.types, item.name, info, item.name_pos)
            for i, v in enumerate(item.variants):
                vi = VariantInfo(program.uids.next(), v.name, info, i, v.pos)
                info.variants.append(vi)
                _enter(m.values, v.name, vi, v.pos)
            program.enums.append(info)
        elif c is S.TraitDecl:
            info = TraitInfo(program.uids.next(), m, item.name, item.pub, item)
            _enter(m.traits, item.name, info, item.name_pos)
            program.traits.append(info)
        elif c is S.FnDecl:
            info = FuncInfo(item.name, m, item, "fn")
            info.pub = item.pub
            info.tparams = _tparams(item.tparams)
            _enter(m.values, item.name, info, item.name_pos)
        m.decls[id(item)] = info


def _enter(ns: dict, name: str, info, pos) -> None:
    if name in ns:
        raise error("dup-name", pos)
    ns[name] = info


# ------------------------------------------------------------------ 3.2 ----
def imports(program: Program, m: Module) -> None:
    for item in m.items:
        if type(item) is not S.Use:
            continue
        target = program.module_by_name.get(item.module)
        if target is None:
            raise error("unknown-module", item.module_pos)
        bound, pos = (item.alias, item.alias_pos) if item.alias else (item.module, item.module_pos)
        if bound in m.imports:
            raise error("dup-name", pos)
        m.imports[bound] = target


# ------------------------------------------------------------------ 3.3 ----
def _check_dups(pairs) -> None:
    seen = set()
    for name, pos in pairs:
        if name in seen:
            raise error("dup-name", pos)
        seen.add(name)


def internal_dups(m: Module) -> None:
    for item in m.items:
        c = type(item)
        if c is S.Use:
            continue
        if c in (S.FnDecl, S.StructDecl, S.EnumDecl, S.ImplDecl):
            _check_dups((g.name, g.pos) for g in item.tparams)
        if c is S.StructDecl:
            _check_dups((f.name, f.pos) for f in item.fields)
        elif c is S.FnDecl:
            _check_dups((p.name, p.pos) for p in item.params)
        elif c in (S.TraitDecl, S.ImplDecl):
            _check_dups((md.name, md.name_pos) for md in item.methods)
            for md in item.methods:
                _check_dups((p.name, p.pos) for p in md.params)


# ------------------------------------------------------------------ 3.4 ----
def _bounds(resolver: Resolver, m: Module, tparams: list[TParam], gparams) -> None:
    for tp, g in zip(tparams, gparams):
        tp.bounds = [resolver.resolve_trait_ref(r, m) for r in g.bounds]


def signatures(program: Program, resolver: Resolver, m: Module) -> None:
    for item in m.items:
        c = type(item)
        if c is S.Use:
            continue
        info = m.decls[id(item)]
        if c is S.FnDecl:
            scope = Scope(m, {tp.name: tp for tp in info.tparams}, None)
            _bounds(resolver, m, info.tparams, item.tparams)
            info.params = [(p.name, resolver.resolve_type(p.ty, scope)) for p in item.params]
            info.ret = resolver.resolve_type(item.ret, scope) if item.ret else UNIT
        elif c is S.StructDecl:
            scope = Scope(m, {tp.name: tp for tp in info.tparams}, None)
            for f in item.fields:
                info.field_index[f.name] = len(info.fields)
                info.fields.append((f.name, resolver.resolve_type(f.ty, scope)))
        elif c is S.EnumDecl:
            scope = Scope(m, {tp.name: tp for tp in info.tparams}, None)
            for v, vi in zip(item.variants, info.variants):
                vi.payload = [resolver.resolve_type(p, scope) for p in v.payloads]
        elif c is S.TraitDecl:
            scope = Scope(m, {}, info.self_param)
            for i, md in enumerate(item.methods):
                ms = MethodSig(md.name, i, info, md)
                ms.params = [resolver.resolve_type(p.ty, scope) for p in md.params]
                ms.ret = resolver.resolve_type(md.ret, scope) if md.ret else UNIT
                info.methods.append(ms)
                info.method_index[md.name] = ms
                if md.body is not None:
                    f = FuncInfo(md.name, m, md, "default")
                    f.tparams = [info.self_param]
                    f.params = [(p.name, t) for p, t in zip(md.params, ms.params)]
                    f.ret = ms.ret
                    f.self_ty = info.self_param
                    ms.default = f
        elif c is S.ImplDecl:
            info.tparams = _tparams(item.tparams)
            tmap = {tp.name: tp for tp in info.tparams}
            _bounds(resolver, m, info.tparams, item.tparams)
            info.trait = resolver.resolve_trait_ref(item.trait, m)
            placeholder = TParam("Self")
            info.head = resolver.resolve_type(item.head, Scope(m, tmap, placeholder))
            scope = Scope(m, tmap, info.head)
            for md in item.methods:
                f = FuncInfo(md.name, m, md, "method")
                f.tparams = info.tparams
                f.params = [(p.name, resolver.resolve_type(p.ty, scope)) for p in md.params]
                f.ret = resolver.resolve_type(md.ret, scope) if md.ret else UNIT
                f.self_ty = info.head
                info.methods.setdefault(md.name, f)
                m.decls[id(md)] = f
    # Default bodies are appended in pass 4 order by the checker.


# ------------------------------------------------------------------ 3.5 ----
def _head_ok(impl: ImplInfo) -> bool:
    h = impl.head
    own = set(impl.tparams)
    c = type(h)
    if c is TPrim:
        return True
    if c is TList:
        return type(h.elem) is TParam and h.elem in own
    if c is TMap:
        return (
            type(h.key) is TParam and type(h.val) is TParam
            and h.key in own and h.val in own and h.key is not h.val
        )
    if c is TNamed:
        args = h.args
        return all(type(a) is TParam and a in own for a in args) and len({id(a) for a in args}) == len(args)
    return False


def _params_in(t, out: set) -> None:
    from .types import prune

    t = prune(t)
    c = type(t)
    if c is TParam:
        out.add(t)
    elif c is TList:
        _params_in(t.elem, out)
    elif c is TMap:
        _params_in(t.key, out)
        _params_in(t.val, out)
    elif c is TNamed:
        for a in t.args:
            _params_in(a, out)


def impls(program: Program, resolver: Resolver, m: Module) -> None:
    for item in m.items:
        if type(item) is not S.ImplDecl:
            continue
        info: ImplInfo = m.decls[id(item)]
        if info.trait in (EQ_TRAIT, ORD_TRAIT, KEY_TRAIT):
            raise error("builtin-trait-impl", item.pos)
        if not _head_ok(info):
            raise error("bad-impl-head", item.head.pos)
        used: set = set()
        _params_in(info.head, used)
        for tp, g in zip(info.tparams, item.tparams):
            if tp not in used:
                raise error("unused-param", g.pos)
        info.head_key = head_key_of(info.head)
        key = (info.trait.uid, info.head_key)
        if key in program.impls:
            raise error("dup-impl", item.pos)
        program.impls[key] = info
        program.impl_list.append(info)
        trait = info.trait
        for ms in trait.methods:
            if ms.default is None and ms.name not in info.methods:
                raise error("missing-method", item.pos)
        smap = {trait.self_param: info.head}
        for md in item.methods:
            ms = trait.method_index.get(md.name)
            if ms is None:
                raise error("extra-method", md.name_pos)
            f = info.methods[md.name]
            ok = len(f.params) == len(ms.params) and all(
                type_equal(pt, subst(st, smap)) for (_, pt), st in zip(f.params, ms.params)
            ) and type_equal(f.ret, subst(ms.ret, smap))
            if not ok:
                raise error("sig-mismatch", md.name_pos)


# ------------------------------------------------------------------ 3.6 ----
def entry_point(program: Program) -> None:
    from .diagnostics import CompileError

    m = program.module_by_name.get("main")
    f = m.values.get("main") if m else None
    if (
        not isinstance(f, FuncInfo)
        or f.tparams
        or f.params
        or f.ret is not UNIT
    ):
        raise CompileError("no-main", 1, 1)
    program.main = f
