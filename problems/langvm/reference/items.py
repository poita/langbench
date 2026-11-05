"""Module splitting, namespaces, declarations and written-type resolution.

This file implements pass 0 (the module stream) and pass 3 (the six item
sub-passes) of section 13.2.
"""

import re

from verrors import CompileError
from lexer import KEYWORDS
from vtypes import (
    TPrim, TList, TMap, TTuple, TFn, TNamed, TParam,
    PRIM_BY_NAME, RESERVED_TYPE_NAMES, holds_key, type_eq, subst,
)
from vast import TAList, TAMap, TATuple, TAFn, TAPath
from vast import IUse, IFn, IStruct, IEnum, ITrait, IImpl

BUILTIN_TRAITS = ('Eq', 'Ord', 'Key')
HEADER_RE = re.compile(r'^@module ([A-Za-z_][A-Za-z0-9_]*)$')


# --- declarations ----------------------------------------------------------

class StructDecl:
    __slots__ = ('name', 'module', 'pub', 'params', 'fields', 'ftypes',
                 'findex', 'item', 'index')

    def __init__(self, name, module, pub, item):
        self.name = name
        self.module = module
        self.pub = pub
        self.params = []
        self.fields = []
        self.ftypes = []
        self.findex = {}
        self.item = item
        self.index = -1

    def member_types(self):
        return self.ftypes


class VariantDecl:
    __slots__ = ('name', 'enum', 'index', 'payloads', 'item')

    def __init__(self, name, enum, index, item):
        self.name = name
        self.enum = enum
        self.index = index
        self.payloads = []
        self.item = item


class EnumDecl:
    __slots__ = ('name', 'module', 'pub', 'params', 'variants', 'vindex',
                 'item', 'index')

    def __init__(self, name, module, pub, item):
        self.name = name
        self.module = module
        self.pub = pub
        self.params = []
        self.variants = []
        self.vindex = {}
        self.item = item
        self.index = -1

    def member_types(self):
        out = []
        for v in self.variants:
            out.extend(v.payloads)
        return out


class TraitDecl:
    __slots__ = ('name', 'module', 'pub', 'methods', 'mindex', 'self_param',
                 'item', 'index')

    def __init__(self, name, module, pub, item):
        self.name = name
        self.module = module
        self.pub = pub
        self.methods = []
        self.mindex = {}
        self.self_param = TParam('Self')
        self.item = item
        self.index = -1


class ImplDecl:
    __slots__ = ('trait', 'params', 'head', 'ctor', 'methods', 'module',
                 'item', 'funcs')

    def __init__(self, trait, module, item):
        self.trait = trait
        self.params = []
        self.head = None
        self.ctor = None
        self.methods = []
        self.module = module
        self.item = item
        self.funcs = []


class Module:
    __slots__ = ('name', 'items', 'types', 'traits', 'values', 'imports',
                 'index', 'lines', 'src', 'toks')

    def __init__(self, name, items, index):
        self.name = name
        self.items = items
        self.lines = items
        self.src = ''
        self.toks = None
        self.types = {}
        self.traits = {}
        self.values = {}
        self.imports = {}
        self.index = index


class Program:
    def __init__(self):
        self.modules = []
        self.modmap = {}
        self.impls = {}
        self.impl_list = []
        self.option = None
        self.result = None
        self.main_fn = None
        self.structs = []
        self.enums = []
        self.traits = []


# --- pass 0: the module stream ---------------------------------------------

def split_lines(text):
    if text == '':
        return []
    parts = text.split('\n')
    terminated = text.endswith('\n')
    if terminated:
        parts.pop()
    out = []
    last = len(parts) - 1
    for idx, p in enumerate(parts):
        if (terminated or idx != last) and p.endswith('\r'):
            p = p[:-1]
        out.append(p)
    return out


def header_name(line):
    m = HEADER_RE.match(line)
    if not m:
        return None
    name = m.group(1)
    if name == '_' or name in KEYWORDS or len(name) > 200:
        return None
    return name


def split_modules(text):
    """Return a list of (name, body_lines, header_line_number)."""
    lines = split_lines(text)
    if not lines or header_name(lines[0]) is None:
        raise CompileError('bad-module', 1, 1)
    for idx, line in enumerate(lines):
        if line.startswith('@') and header_name(line) is None:
            raise CompileError('bad-module', idx + 1, 1)
    mods = []
    cur = None
    for idx, line in enumerate(lines):
        if line.startswith('@'):
            cur = (header_name(line), [], idx + 1)
            mods.append(cur)
        else:
            cur[1].append(line)
    seen = {}
    for name, _body, hline in mods:
        if name in seen:
            raise CompileError('dup-module', hline, 1)
        seen[name] = True
    return mods


# --- the prelude -----------------------------------------------------------

def _make_prelude():
    pm = Module('', [], -1)
    option = EnumDecl('Option', pm, True, None)
    t = TParam('T')
    option.params = [t]
    some = VariantDecl('Some', option, 0, None)
    some.payloads = [t]
    none = VariantDecl('None', option, 1, None)
    option.variants = [some, none]
    option.vindex = {'Some': some, 'None': none}

    result = EnumDecl('Result', pm, True, None)
    rt = TParam('T')
    re_ = TParam('E')
    result.params = [rt, re_]
    ok = VariantDecl('Ok', result, 0, None)
    ok.payloads = [rt]
    err = VariantDecl('Err', result, 1, None)
    err.payloads = [re_]
    result.variants = [ok, err]
    result.vindex = {'Ok': ok, 'Err': err}
    return option, result


# The prelude `Option` and `Result` declarations are process-wide singletons so
# that the built-in signature table can mention them.
PRELUDE_OPTION, PRELUDE_RESULT = _make_prelude()


def make_prelude():
    return PRELUDE_OPTION, PRELUDE_RESULT


# --- type resolution -------------------------------------------------------

class TyCtx:
    """What a written type may mention."""
    __slots__ = ('module', 'params', 'self_ty', 'prog')

    def __init__(self, prog, module, params=None, self_ty=None):
        self.prog = prog
        self.module = module
        self.params = params or {}
        self.self_ty = self_ty


def resolve_type(ctx, ast):
    k = type(ast)
    if k is TAList:
        return TList(resolve_type(ctx, ast.elem))
    if k is TAMap:
        key = resolve_type(ctx, ast.key)
        val = resolve_type(ctx, ast.val)
        if not holds_key(key):
            raise CompileError('bad-key-type', ast.line, ast.col)
        return TMap(key, val)
    if k is TATuple:
        if len(ast.parts) > 8:
            raise CompileError('bad-arity', ast.line, ast.col)
        return TTuple([resolve_type(ctx, p) for p in ast.parts])
    if k is TAFn:
        if len(ast.params) > 16:
            raise CompileError('bad-arity', ast.line, ast.col)
        params = [resolve_type(ctx, p) for p in ast.params]
        ret = resolve_type(ctx, ast.ret) if ast.ret is not None else PRIM_BY_NAME['Unit']
        return TFn(params, ret)
    if k is TAPath:
        return resolve_path_type(ctx, ast)
    raise AssertionError('bad type ast')


def resolve_path_type(ctx, ast):
    prog = ctx.prog
    nargs = len(ast.args)
    if ast.mod is None:
        name = ast.name
        if name in ctx.params:
            if nargs:
                raise CompileError('arity-type', ast.line, ast.col)
            return ctx.params[name]
        if name == 'Self':
            if ctx.self_ty is None:
                raise CompileError('self-outside', ast.line, ast.col)
            if nargs:
                raise CompileError('arity-type', ast.line, ast.col)
            return ctx.self_ty
        if name in PRIM_BY_NAME:
            if nargs:
                raise CompileError('arity-type', ast.line, ast.col)
            return PRIM_BY_NAME[name]
        decl = ctx.module.types.get(name)
        if decl is None:
            if name == 'Option':
                decl = prog.option
            elif name == 'Result':
                decl = prog.result
        if decl is None:
            raise CompileError('unknown-type', ast.line, ast.col)
        return apply_args(ctx, decl, ast)
    target = ctx.module.imports.get(ast.mod)
    if target is None:
        raise CompileError('unknown-module', ast.line, ast.col)
    decl = target.types.get(ast.name)
    if decl is None:
        raise CompileError('unknown-type', ast.nline, ast.ncol)
    if not decl.pub and target is not ctx.module:
        raise CompileError('not-public', ast.nline, ast.ncol)
    return apply_args(ctx, decl, ast)


def apply_args(ctx, decl, ast):
    if len(ast.args) != len(decl.params):
        raise CompileError('arity-type', ast.line, ast.col)
    args = [resolve_type(ctx, a) for a in ast.args]
    return TNamed(decl, args)


def resolve_trait(prog, module, ref):
    """Resolve a trait reference to a TraitDecl or a built-in trait name."""
    if ref.mod is None:
        decl = module.traits.get(ref.name)
        if decl is not None:
            return decl
        if ref.name in BUILTIN_TRAITS:
            return ref.name
        raise CompileError('unknown-trait', ref.nline, ref.ncol)
    target = module.imports.get(ref.mod)
    if target is None:
        raise CompileError('unknown-module', ref.line, ref.col)
    decl = target.traits.get(ref.name)
    if decl is None:
        raise CompileError('unknown-trait', ref.nline, ref.ncol)
    if not decl.pub and target is not module:
        raise CompileError('not-public', ref.nline, ref.ncol)
    return decl


def visible_traits(prog, module):
    """Every trait visible in `module`, in a deterministic order."""
    out = []
    for name in sorted(module.traits):
        out.append(module.traits[name])
    for alias in sorted(module.imports):
        target = module.imports[alias]
        if target is module:
            continue
        for name in sorted(target.traits):
            d = target.traits[name]
            if d.pub and d not in out:
                out.append(d)
    return out


# --- pass 3 ----------------------------------------------------------------

def build_program(mods):
    prog = Program()
    prog.option, prog.result = make_prelude()
    for i, (name, body, _hline) in enumerate(mods):
        m = Module(name, body, i)
        prog.modules.append(m)
        prog.modmap[name] = m
    return prog


def pass_declare(prog):
    for m in prog.modules:
        for it in m.items:
            k = type(it)
            if k is IUse:
                continue
            if k is IImpl:
                continue
            if k is IStruct or k is IEnum or k is ITrait:
                if it.name in RESERVED_TYPE_NAMES:
                    raise CompileError('reserved-name', it.nline, it.ncol)
            if k is IStruct:
                if it.name in m.types:
                    raise CompileError('dup-name', it.nline, it.ncol)
                decl = StructDecl(it.name, m, it.pub, it)
                decl.index = len(prog.structs)
                prog.structs.append(decl)
                it.decl = decl
                m.types[it.name] = decl
            elif k is IEnum:
                if it.name in m.types:
                    raise CompileError('dup-name', it.nline, it.ncol)
                decl = EnumDecl(it.name, m, it.pub, it)
                decl.index = len(prog.enums)
                prog.enums.append(decl)
                it.decl = decl
                m.types[it.name] = decl
                for vi, v in enumerate(it.variants):
                    if v.name in m.values:
                        raise CompileError('dup-name', v.line, v.col)
                    vd = VariantDecl(v.name, decl, vi, v)
                    decl.variants.append(vd)
                    decl.vindex[v.name] = vd
                    m.values[v.name] = ('variant', vd)
            elif k is ITrait:
                if it.name in m.traits:
                    raise CompileError('dup-name', it.nline, it.ncol)
                decl = TraitDecl(it.name, m, it.pub, it)
                decl.index = len(prog.traits)
                prog.traits.append(decl)
                it.decl = decl
                m.traits[it.name] = decl
                for mi, meth in enumerate(it.methods):
                    meth.index = mi
                    decl.methods.append(meth)
                    if meth.name not in decl.mindex:
                        decl.mindex[meth.name] = meth
            elif k is IFn:
                if it.name in m.values:
                    raise CompileError('dup-name', it.nline, it.ncol)
                m.values[it.name] = ('fn', it)


def pass_imports(prog):
    for m in prog.modules:
        for it in m.items:
            if type(it) is not IUse:
                continue
            target = prog.modmap.get(it.name)
            if target is None:
                raise CompileError('unknown-module', it.nline, it.ncol)
            bound = it.alias if it.alias is not None else it.name
            if bound in m.imports:
                raise CompileError('dup-name', it.aline, it.acol)
            m.imports[bound] = target


def check_dups(names):
    """Return the first repeated entry, as (line, col)."""
    seen = set()
    for name, line, col in names:
        if name in seen:
            return (line, col)
        seen.add(name)
    return None


def pass_internal_dups(prog):
    for m in prog.modules:
        for it in m.items:
            k = type(it)
            if k is IUse:
                continue
            gens = getattr(it, 'generics', [])
            bad = check_dups([(g.name, g.line, g.col) for g in gens])
            if bad:
                raise CompileError('dup-name', bad[0], bad[1])
            if k is IStruct:
                bad = check_dups([(f.name, f.line, f.col) for f in it.fields])
                if bad:
                    raise CompileError('dup-name', bad[0], bad[1])
            elif k is IFn:
                bad = check_dups([(p.name, p.line, p.col) for p in it.params])
                if bad:
                    raise CompileError('dup-name', bad[0], bad[1])
            elif k is ITrait or k is IImpl:
                bad = check_dups([(d.name, d.nline, d.ncol)
                                  for d in it.methods])
                if bad:
                    raise CompileError('dup-name', bad[0], bad[1])
                for d in it.methods:
                    bad = check_dups([(p.name, p.line, p.col)
                                      for p in d.params])
                    if bad:
                        raise CompileError('dup-name', bad[0], bad[1])


def item_params(prog, m, it):
    """Create the rigid parameters of an item and resolve their bounds."""
    params = {}
    order = []
    for g in it.generics:
        tp = TParam(g.name)
        g.tp = tp
        params[g.name] = tp
        order.append(tp)
    for g in it.generics:
        for ref in g.bounds:
            tr = resolve_trait(prog, m, ref)
            ref.decl = tr
            g.tp.bounds.append(tr)
    return params, order


def pass_signatures(prog):
    for m in prog.modules:
        for it in m.items:
            k = type(it)
            if k is IUse:
                continue
            if k is IFn:
                params, order = item_params(prog, m, it)
                ctx = TyCtx(prog, m, params, None)
                ptypes = []
                for p in it.params:
                    p.ty = resolve_type(ctx, p.ann)
                    ptypes.append(p.ty)
                ret = (resolve_type(ctx, it.ret) if it.ret is not None
                       else PRIM_BY_NAME['Unit'])
                it.sig = (order, ptypes, ret)
            elif k is IStruct:
                params, order = item_params(prog, m, it)
                ctx = TyCtx(prog, m, params, None)
                decl = it.decl
                decl.params = order
                for f in it.fields:
                    ty = resolve_type(ctx, f.ann)
                    decl.fields.append(f)
                    decl.findex[f.name] = len(decl.ftypes)
                    decl.ftypes.append(ty)
            elif k is IEnum:
                params, order = item_params(prog, m, it)
                ctx = TyCtx(prog, m, params, None)
                decl = it.decl
                decl.params = order
                for vi, v in enumerate(it.variants):
                    vd = decl.variants[vi]
                    for pay in v.payloads:
                        vd.payloads.append(resolve_type(ctx, pay))
            elif k is ITrait:
                decl = it.decl
                decl.self_param.bounds = [decl]
                ctx = TyCtx(prog, m, {}, decl.self_param)
                for meth in it.methods:
                    ptypes = []
                    for p in meth.params:
                        p.ty = resolve_type(ctx, p.ann)
                        ptypes.append(p.ty)
                    ret = (resolve_type(ctx, meth.ret) if meth.ret is not None
                           else PRIM_BY_NAME['Unit'])
                    meth.sig = (ptypes, ret)
            elif k is IImpl:
                params, order = item_params(prog, m, it)
                tr = resolve_trait(prog, m, it.traitref)
                it.traitref.decl = tr
                ctx = TyCtx(prog, m, params, None)
                head = resolve_type(ctx, it.head)
                impl = ImplDecl(tr, m, it)
                impl.params = order
                impl.head = head
                it.impl = impl
                mctx = TyCtx(prog, m, params, head)
                for meth in it.methods:
                    ptypes = []
                    for p in meth.params:
                        p.ty = resolve_type(mctx, p.ann)
                        ptypes.append(p.ty)
                    ret = (resolve_type(mctx, meth.ret)
                           if meth.ret is not None else PRIM_BY_NAME['Unit'])
                    meth.sig = (ptypes, ret)


def check_impl_head(impl):
    """True when the head is a primitive, [P], #[P: Q] or Name<distinct Ps>."""
    head = impl.head
    own = impl.params
    k = type(head)
    if k is TPrim:
        impl.ctor = head.name
        return True
    if k is TList:
        if type(head.elem) is TParam and head.elem in own:
            impl.ctor = 'List'
            return True
        return False
    if k is TMap:
        if (type(head.key) is TParam and type(head.val) is TParam
                and head.key in own and head.val in own
                and head.key is not head.val):
            impl.ctor = 'Map'
            return True
        return False
    if k is TNamed:
        seen = []
        for a in head.args:
            if type(a) is not TParam or a not in own or a in seen:
                return False
            seen.append(a)
        impl.ctor = head.decl
        return True
    return False


def param_in_head(tp, ty):
    k = type(ty)
    if k is TParam:
        return ty is tp
    if k is TList:
        return param_in_head(tp, ty.elem)
    if k is TMap:
        return param_in_head(tp, ty.key) or param_in_head(tp, ty.val)
    if k is TNamed:
        return any(param_in_head(tp, a) for a in ty.args)
    return False


def pass_impls(prog):
    for m in prog.modules:
        for it in m.items:
            if type(it) is not IImpl:
                continue
            impl = it.impl
            if isinstance(impl.trait, str):
                raise CompileError('builtin-trait-impl', it.line, it.col)
            if not check_impl_head(impl):
                raise CompileError('bad-impl-head', it.head.line, it.head.col)
            for g in it.generics:
                if not param_in_head(g.tp, impl.head):
                    raise CompileError('unused-param', g.line, g.col)
            kk = impl_key(impl.trait, impl.ctor)
            if kk in prog.impls:
                raise CompileError('dup-impl', it.line, it.col)
            trait = impl.trait
            defined = {}
            for meth in it.methods:
                if meth.name not in defined:
                    defined[meth.name] = meth
            for tm in trait.methods:
                if tm.body is None and tm.name not in defined:
                    raise CompileError('missing-method', it.line, it.col)
            mapping = {trait.self_param: impl.head}
            for meth in it.methods:
                tm = trait.mindex.get(meth.name)
                if tm is None:
                    raise CompileError('extra-method', meth.nline, meth.ncol)
                tp, tret = tm.sig
                ip, iret = meth.sig
                if len(tp) != len(ip):
                    raise CompileError('sig-mismatch', meth.nline, meth.ncol)
                ok = True
                for a, b in zip(tp, ip):
                    if not type_eq(subst(a, mapping), b):
                        ok = False
                        break
                if ok and not type_eq(subst(tret, mapping), iret):
                    ok = False
                if not ok:
                    raise CompileError('sig-mismatch', meth.nline, meth.ncol)
                meth.index = tm.index
            impl.methods = [None] * len(trait.methods)
            for meth in it.methods:
                impl.methods[meth.index] = meth
            prog.impls[kk] = impl
            prog.impl_list.append(impl)


def impl_key(trait, ctor):
    return (id(trait), ctor if isinstance(ctor, str) else id(ctor))


def pass_entry(prog):
    m = prog.modmap.get('main')
    if m is None:
        raise CompileError('no-main', 1, 1)
    ent = m.values.get('main')
    if ent is None or ent[0] != 'fn':
        raise CompileError('no-main', 1, 1)
    fn = ent[1]
    order, ptypes, ret = fn.sig
    if order or ptypes or type(ret) is not TPrim or ret.name != 'Unit':
        raise CompileError('no-main', 1, 1)
    prog.main_fn = fn


def run_item_passes(prog):
    pass_declare(prog)
    pass_imports(prog)
    pass_internal_dups(prog)
    pass_signatures(prog)
    pass_impls(prog)
    pass_entry(prog)
