"""The bidirectional type checker (pass 4 of section 13.2).

Besides rejecting programs, this pass annotates the AST for the bytecode
compiler: every expression gets its type, every name its resolution, every
binding a local slot, and every lambda its capture list.
"""

from verrors import CompileError
from vtypes import (
    TPrim, TList, TMap, TTuple, TFn, TNamed, TParam, TVar,
    T_INT, T_FLOAT, T_BOOL, T_CHAR, T_STR, T_UNIT,
    prune, resolve, is_ground, unify, subst, head_ctor,
    holds_eq, holds_ord, holds_key,
)
from vast import (
    EInt, EFloat, EStr, EChar, EBool, ESelf, EPath, EUnary, EBinary, ECall,
    EMethod, EIndex, EField, EStructLit, EList, EMap, ETuple, ELambda, EIf,
    EMatch, EBlock,
    SLet, SVar, SAssign, SExpr, SWhile, SForSeq, SForRange, SBreak, SContinue,
    SReturn,
    PWild, PInt, PFloat, PStr, PChar, PBool, PBind, PVariant, PStruct, PTuple,
    PList,
    IUse, IFn, IStruct, IEnum, ITrait, IImpl,
)
from items import (
    StructDecl, EnumDecl, TyCtx, resolve_type, visible_traits, impl_key,
)
from blib import BUILTIN_SIGS, BUILTIN_INDEX
from exhaust import useful, WILD

ARITH_OPS = ('+', '-', '*', '/', '%')
BIT_OPS = ('&', '|', '^', '<<', '>>')
ORD_OPS = ('<', '<=', '>', '>=')
EQ_OPS = ('==', '!=')


def is_unit(t):
    t = prune(t)
    return type(t) is TPrim and t.name == 'Unit'


def is_prim(t, name):
    t = prune(t)
    return type(t) is TPrim and t.name == name


class Binding:
    __slots__ = ('name', 'ty', 'mutable', 'slot', 'func')

    def __init__(self, name, ty, mutable, slot, func):
        self.name = name
        self.ty = ty
        self.mutable = mutable
        self.slot = slot
        self.func = func


class FuncInfo:
    __slots__ = ('parent', 'ret', 'nslots', 'captures', 'upidx', 'loops',
                 'kind', 'nparams', 'index', 'code', 'node', 'name')

    def __init__(self, parent, ret, kind, name=''):
        self.parent = parent
        self.ret = ret
        self.nslots = 0
        self.captures = []
        self.upidx = {}
        self.loops = 0
        self.kind = kind
        self.nparams = 0
        self.index = -1
        self.code = None
        self.node = None
        self.name = name

    def slot(self):
        s = self.nslots
        self.nslots += 1
        return s


# --- divergence ------------------------------------------------------------

def diverges_expr(e):
    k = type(e)
    if k is EBlock:
        for s in e.stmts:
            if diverges_stmt(s):
                return True
        return e.tail is not None and diverges_expr(e.tail)
    if k is EIf:
        return (e.els is not None and diverges_expr(e.then)
                and diverges_expr(e.els))
    if k is EMatch:
        return len(e.arms) > 0 and all(diverges_expr(a.body) for a in e.arms)
    return False


def diverges_stmt(s):
    k = type(s)
    if k is SReturn:
        return True
    if k is SBreak or k is SContinue:
        return True
    if k is SExpr:
        return diverges_expr(s.expr)
    if k is SLet or k is SVar:
        return diverges_expr(s.expr)
    if k is SAssign:
        return diverges_expr(s.expr)
    return False


# --- the checker -----------------------------------------------------------

class Checker:
    def __init__(self, prog):
        self.prog = prog
        self.module = None
        self.tyctx = None
        self.scopes = []
        self.func = None
        self.self_bind = None
        self.var_scopes = []
        self.trait_cache = {}
        self.funcs = []

    # -- plumbing --------------------------------------------------------

    def err(self, kind, node):
        raise CompileError(kind, node.line, node.col)

    def at(self, kind, line, col):
        raise CompileError(kind, line, col)

    def push_scope(self):
        self.scopes.append({})

    def pop_scope(self):
        self.scopes.pop()

    def declare(self, name, ty, mutable):
        b = Binding(name, resolve(ty), mutable, self.func.slot(), self.func)
        self.scopes[-1][name] = b
        return b

    def lookup(self, name):
        for i in range(len(self.scopes) - 1, -1, -1):
            b = self.scopes[i].get(name)
            if b is not None:
                return b
        return None

    def access(self, b):
        """How the running function reaches binding `b`, capturing if needed."""
        if b.func is self.func:
            return ('local', b.slot)
        chain = []
        f = self.func
        while f is not None and f is not b.func:
            chain.append(f)
            f = f.parent
        for g in reversed(chain):
            if b not in g.upidx:
                g.upidx[b] = len(g.captures)
                g.captures.append(b)
        return ('upval', self.func.upidx[b])

    def new_func(self, parent, ret, kind, name=''):
        f = FuncInfo(parent, ret, kind, name)
        f.index = len(self.funcs)
        self.funcs.append(f)
        return f

    def push_vars(self):
        self.var_scopes.append([])

    def pop_vars(self):
        return self.var_scopes.pop()

    def new_var(self):
        v = TVar()
        if self.var_scopes:
            self.var_scopes[-1].append(v)
        return v

    def traits_of_module(self):
        m = self.module
        got = self.trait_cache.get(m.name)
        if got is None:
            got = visible_traits(self.prog, m)
            self.trait_cache[m.name] = got
        return got

    # -- bounds ----------------------------------------------------------

    def bound_holds(self, ty, bound):
        if bound == 'Eq':
            return holds_eq(ty)
        if bound == 'Ord':
            return holds_ord(ty)
        if bound == 'Key':
            return holds_key(ty)
        return self.satisfies(ty, bound)

    def satisfies(self, ty, trait):
        ty = prune(ty)
        if type(ty) is TParam:
            return trait in ty.bounds
        ctor = head_ctor(ty)
        if ctor is None:
            return False
        impl = self.prog.impls.get(impl_key(trait, ctor))
        if impl is None:
            return False
        mapping = self.match_head(impl, ty)
        for tp in impl.params:
            for b in tp.bounds:
                if not self.bound_holds(mapping[tp], b):
                    return False
        return True

    def match_head(self, impl, ty):
        head = prune(impl.head)
        ty = prune(ty)
        k = type(head)
        if k is TList:
            return {head.elem: ty.elem}
        if k is TMap:
            return {head.key: ty.key, head.val: ty.val}
        if k is TNamed:
            return dict(zip(head.args, ty.args))
        return {}

    def find_impl(self, ty, trait):
        ctor = head_ctor(prune(ty))
        if ctor is None:
            return None
        return self.prog.impls.get(impl_key(trait, ctor))

    # -- entry point -----------------------------------------------------

    def run(self):
        for m in self.prog.modules:
            self.module = m
            for it in m.items:
                k = type(it)
                if k is IUse or k is IStruct or k is IEnum:
                    continue
                if k is IFn:
                    self.check_fn(it)
                elif k is ITrait:
                    self.check_trait(it)
                elif k is IImpl:
                    self.check_impl(it)

    def item_params(self, it):
        return {g.name: g.tp for g in getattr(it, 'generics', [])}

    def check_fn(self, it):
        order, ptypes, ret = it.sig
        self.tyctx = TyCtx(self.prog, self.module, self.item_params(it), None)
        f = self.new_func(None, ret, 'fn', it.name)
        f.node = it
        it.info = f
        self.func = f
        self.self_bind = None
        self.scopes = [{}]
        for p, t in zip(it.params, ptypes):
            p.bind = self.declare(p.name, t, False)
        f.nparams = len(it.params)
        self.check_fn_body(it.body, ret, it.line, it.col)
        self.scopes = []
        self.func = None

    def check_trait(self, it):
        decl = it.decl
        self.tyctx = TyCtx(self.prog, self.module, {}, decl.self_param)
        for meth in it.methods:
            if meth.body is None:
                continue
            ptypes, ret = meth.sig
            f = self.new_func(None, ret, 'method', it.name + '.' + meth.name)
            f.node = meth
            meth.info = f
            self.func = f
            self.scopes = [{}]
            self.self_bind = self.declare('self', decl.self_param, False)
            for p, t in zip(meth.params, ptypes):
                p.bind = self.declare(p.name, t, False)
            f.nparams = 1 + len(meth.params)
            self.check_fn_body(meth.body, ret, meth.line, meth.col)
            self.scopes = []
            self.func = None
            self.self_bind = None

    def check_impl(self, it):
        impl = it.impl
        self.tyctx = TyCtx(self.prog, self.module, self.item_params(it),
                           impl.head)
        for meth in it.methods:
            ptypes, ret = meth.sig
            f = self.new_func(None, ret, 'method', meth.name)
            f.node = meth
            meth.info = f
            self.func = f
            self.scopes = [{}]
            self.self_bind = self.declare('self', impl.head, False)
            for p, t in zip(meth.params, ptypes):
                p.bind = self.declare(p.name, t, False)
            f.nparams = 1 + len(meth.params)
            self.check_fn_body(meth.body, ret, meth.line, meth.col)
            self.scopes = []
            self.func = None
            self.self_bind = None

    def check_fn_body(self, block, ret, line, col):
        """A function, method or lambda body: 11.6 applies, not the block
        rule."""
        self.push_scope()
        for s in block.stmts:
            self.stmt(s)
        if block.tail is not None:
            self.check(block.tail, ret)
        elif not is_unit(ret) and not diverges_expr(block):
            raise CompileError('missing-return', line, col)
        self.pop_scope()
        block.ty = ret

    # -- statements ------------------------------------------------------

    def stmt(self, s):
        k = type(s)
        if k is SLet:
            if s.ann is not None:
                ann = resolve_type(self.tyctx, s.ann)
                self.check(s.expr, ann)
                ty = ann
            else:
                ty = self.infer(s.expr)
            self.pattern(s.pat, resolve(ty), {})
            if not irrefutable(s.pat):
                raise CompileError('refutable-pattern', s.pat.line, s.pat.col)
        elif k is SVar:
            if s.ann is not None:
                ann = resolve_type(self.tyctx, s.ann)
                self.check(s.expr, ann)
                ty = ann
            else:
                ty = self.infer(s.expr)
            s.bind = self.declare(s.name, ty, True)
        elif k is SAssign:
            self.assign(s)
        elif k is SExpr:
            self.infer(s.expr)
        elif k is SWhile:
            self.check(s.cond, T_BOOL)
            self.func.loops += 1
            self.stmt_block(s.body)
            self.func.loops -= 1
        elif k is SForSeq:
            ty = prune(self.infer(s.seq))
            if type(ty) is TList:
                elem = ty.elem
                s.kind = 'list'
            elif is_prim(ty, 'Str'):
                elem = T_CHAR
                s.kind = 'str'
            else:
                raise CompileError('not-iterable', s.seq.line, s.seq.col)
            self.push_scope()
            self.pattern(s.pat, resolve(elem), {})
            if not irrefutable(s.pat):
                raise CompileError('refutable-pattern', s.pat.line, s.pat.col)
            self.func.loops += 1
            self.stmt_block(s.body)
            self.func.loops -= 1
            self.pop_scope()
        elif k is SForRange:
            self.check(s.lo, T_INT)
            self.check(s.hi, T_INT)
            self.push_scope()
            self.pattern(s.pat, T_INT, {})
            if not irrefutable(s.pat):
                raise CompileError('refutable-pattern', s.pat.line, s.pat.col)
            self.func.loops += 1
            self.stmt_block(s.body)
            self.func.loops -= 1
            self.pop_scope()
        elif k is SBreak or k is SContinue:
            if self.func.loops == 0:
                raise CompileError('break-outside', s.line, s.col)
        elif k is SReturn:
            ret = self.func.ret
            if ret is None:
                raise CompileError('cannot-infer', s.line, s.col)
            if s.expr is None:
                if not is_unit(ret):
                    raise CompileError('type-mismatch', s.line, s.col)
            elif is_unit(ret):
                got = self.infer(s.expr)
                if not is_unit(got):
                    raise CompileError('type-mismatch', s.line, s.col)
            else:
                self.check(s.expr, ret)
        else:
            raise AssertionError('bad statement')

    def stmt_block(self, b):
        self.push_scope()
        for s in b.stmts:
            self.stmt(s)
        if b.tail is not None:
            self.infer(b.tail)
        self.pop_scope()
        b.ty = T_UNIT

    def assign(self, s):
        t = s.target
        k = type(t)
        if k is EPath and t.mod is None:
            b = self.lookup(t.name)
            if b is None:
                raise CompileError('unknown-name', t.nline, t.ncol)
            if not b.mutable:
                raise CompileError('assign-immutable', t.nline, t.ncol)
            if b.func is not self.func:
                raise CompileError('assign-captured', t.nline, t.ncol)
            t.res = ('local', b.slot)
            t.ty = b.ty
            s.bind = b
            self.check(s.expr, b.ty)
        elif k is EIndex:
            ty = prune(self.infer(t.obj))
            if type(ty) is TList:
                t.kind = 'list'
                self.check(t.index, T_INT)
                self.check(s.expr, ty.elem)
            elif type(ty) is TMap:
                t.kind = 'map'
                self.check(t.index, ty.key)
                self.check(s.expr, ty.val)
            else:
                raise CompileError('bad-target', t.obj.line, t.obj.col)
        else:
            raise CompileError('bad-target', t.line, t.col)

    # -- expressions: synthesis -------------------------------------------

    def infer(self, e):
        k = type(e)
        if k is EInt:
            e.ty = T_INT
            return T_INT
        if k is EFloat:
            e.ty = T_FLOAT
            return T_FLOAT
        if k is EStr:
            e.ty = T_STR
            return T_STR
        if k is EChar:
            e.ty = T_CHAR
            return T_CHAR
        if k is EBool:
            e.ty = T_BOOL
            return T_BOOL
        if k is ESelf:
            if self.self_bind is None:
                raise CompileError('self-outside', e.line, e.col)
            e.res = self.access(self.self_bind)
            e.ty = self.self_bind.ty
            return e.ty
        if k is EPath:
            return self.infer_path(e)
        if k is EUnary:
            return self.infer_unary(e)
        if k is EBinary:
            return self.infer_binary(e)
        if k is ECall:
            return self.call(e, None)
        if k is EMethod:
            return self.method_call(e)
        if k is EIndex:
            return self.infer_index(e)
        if k is EField:
            return self.infer_field(e)
        if k is EStructLit:
            return self.struct_lit(e, None)
        if k is EList:
            return self.infer_list(e)
        if k is EMap:
            return self.infer_map(e)
        if k is ETuple:
            return self.infer_tuple(e)
        if k is ELambda:
            return self.infer_lambda(e)
        if k is EIf:
            return self.infer_if(e)
        if k is EMatch:
            return self.infer_match(e)
        if k is EBlock:
            return self.infer_block(e)
        raise AssertionError('bad expression %r' % (e,))

    def infer_path(self, e):
        res = self.resolve_value(e)
        tag = res[0]
        if tag == 'local':
            b = res[1]
            e.res = self.access(b)
            e.ty = b.ty
            return b.ty
        if tag == 'variant0':
            return self.call_variant(e, res[1], [], None, e)
        raise CompileError('bad-value-ref', e.nline, e.ncol)

    def resolve_value(self, e):
        """Resolve a value path; see sections 5.4 and 10.2."""
        if e.mod is None:
            b = self.lookup(e.name)
            if b is not None:
                return ('local', b)
            ent = self.module.values.get(e.name)
            if ent is None:
                if e.name == 'Some':
                    return self.prelude_variant('Some')
                if e.name == 'None':
                    return self.prelude_variant('None')
                if e.name == 'Ok':
                    return self.prelude_variant('Ok')
                if e.name == 'Err':
                    return self.prelude_variant('Err')
                if e.name in BUILTIN_SIGS:
                    return ('builtin', e.name)
                if e.name in self.module.types or e.name in ('Option',
                                                             'Result'):
                    raise CompileError('bad-value-ref', e.nline, e.ncol)
                raise CompileError('unknown-name', e.nline, e.ncol)
            if ent[0] == 'fn':
                return ('fn', ent[1])
            vd = ent[1]
            if not vd.payloads:
                return ('variant0', vd)
            return ('variant', vd)
        target = self.module.imports.get(e.mod)
        if target is not None:
            ent = target.values.get(e.name)
            if ent is None:
                raise CompileError('unknown-name', e.nline, e.ncol)
            if ent[0] == 'fn':
                if not ent[1].pub and target is not self.module:
                    raise CompileError('not-public', e.nline, e.ncol)
                return ('fn', ent[1])
            vd = ent[1]
            if not vd.enum.pub and target is not self.module:
                raise CompileError('not-public', e.nline, e.ncol)
            if not vd.payloads:
                return ('variant0', vd)
            return ('variant', vd)
        for tr in self.traits_of_module():
            if tr.name == e.mod:
                meth = tr.mindex.get(e.name)
                if meth is None:
                    raise CompileError('unknown-name', e.nline, e.ncol)
                return ('traitmethod', tr, meth)
        if e.mod in ('Eq', 'Ord', 'Key'):
            # A built-in trait is a visible trait name with no methods at all.
            raise CompileError('unknown-name', e.nline, e.ncol)
        raise CompileError('unknown-module', e.line, e.col)

    def prelude_variant(self, name):
        enum = self.prog.option if name in ('Some', 'None') else self.prog.result
        vd = enum.vindex[name]
        if not vd.payloads:
            return ('variant0', vd)
        return ('variant', vd)

    def infer_unary(self, e):
        if e.op == '-':
            t = prune(self.infer(e.operand))
            if is_prim(t, 'Int'):
                e.kind = 'int'
            elif is_prim(t, 'Float'):
                e.kind = 'float'
            else:
                raise CompileError('type-mismatch', e.operand.line,
                                   e.operand.col)
            e.ty = t
            return t
        if e.op == '!':
            self.check(e.operand, T_BOOL)
            e.kind = 'not'
            e.ty = T_BOOL
            return T_BOOL
        self.check(e.operand, T_INT)
        e.kind = 'bnot'
        e.ty = T_INT
        return T_INT

    def infer_binary(self, e):
        op = e.op
        if op in ARITH_OPS:
            left = prune(self.infer(e.left))
            if is_prim(left, 'Int'):
                e.kind = 'int'
            elif is_prim(left, 'Float'):
                e.kind = 'float'
            else:
                raise CompileError('type-mismatch', e.left.line, e.left.col)
            if op == '%' and e.kind == 'float':
                raise CompileError('type-mismatch', e.left.line, e.left.col)
            self.check(e.right, left)
            e.ty = left
            return left
        if op == '++':
            left = prune(self.infer(e.left))
            if is_prim(left, 'Str'):
                e.kind = 'str'
            elif type(left) is TList:
                e.kind = 'list'
            else:
                raise CompileError('type-mismatch', e.left.line, e.left.col)
            self.check(e.right, left)
            e.ty = left
            return left
        if op in BIT_OPS:
            self.check(e.left, T_INT)
            self.check(e.right, T_INT)
            e.kind = 'bits'
            e.ty = T_INT
            return T_INT
        if op in ORD_OPS:
            left = self.infer(e.left)
            if not holds_ord(left):
                raise CompileError('not-ord', e.left.line, e.left.col)
            self.check(e.right, left)
            e.kind = 'cmp'
            e.ty = T_BOOL
            return T_BOOL
        if op in EQ_OPS:
            left = self.infer(e.left)
            if not holds_eq(left):
                raise CompileError('not-eq', e.left.line, e.left.col)
            self.check(e.right, left)
            e.kind = 'eq'
            e.ty = T_BOOL
            return T_BOOL
        self.check(e.left, T_BOOL)
        self.check(e.right, T_BOOL)
        e.kind = 'logic'
        e.ty = T_BOOL
        return T_BOOL

    def infer_index(self, e):
        ty = prune(self.infer(e.obj))
        if type(ty) is TList:
            self.check(e.index, T_INT)
            e.kind = 'list'
            e.ty = ty.elem
        elif is_prim(ty, 'Str'):
            self.check(e.index, T_INT)
            e.kind = 'str'
            e.ty = T_CHAR
        elif type(ty) is TMap:
            self.check(e.index, ty.key)
            e.kind = 'map'
            e.ty = ty.val
        else:
            raise CompileError('not-indexable', e.obj.line, e.obj.col)
        return e.ty

    def infer_field(self, e):
        ty = prune(self.infer(e.obj))
        if type(ty) is not TNamed or not isinstance(ty.decl, StructDecl):
            raise CompileError('not-struct', e.obj.line, e.obj.col)
        decl = ty.decl
        idx = decl.findex.get(e.name)
        if idx is None:
            raise CompileError('unknown-field', e.nline, e.ncol)
        e.idx = idx
        mapping = dict(zip(decl.params, ty.args))
        e.ty = subst(decl.ftypes[idx], mapping)
        return e.ty

    def infer_list(self, e):
        if not e.elems:
            raise CompileError('cannot-infer', e.line, e.col)
        t = self.infer(e.elems[0])
        for x in e.elems[1:]:
            self.check(x, t)
        e.ty = TList(t)
        return e.ty

    def infer_map(self, e):
        if not e.entries:
            raise CompileError('cannot-infer', e.line, e.col)
        k0, v0 = e.entries[0]
        kt = self.infer(k0)
        if not holds_key(kt):
            raise CompileError('bad-key-type', k0.line, k0.col)
        vt = self.infer(v0)
        for k, v in e.entries[1:]:
            self.check(k, kt)
            self.check(v, vt)
        e.ty = TMap(kt, vt)
        return e.ty

    def infer_tuple(self, e):
        if len(e.parts) > 8:
            raise CompileError('bad-arity', e.line, e.col)
        parts = [self.infer(p) for p in e.parts]
        e.ty = TTuple(parts)
        return e.ty

    def infer_block(self, e):
        self.push_scope()
        for s in e.stmts:
            self.stmt(s)
        ty = self.infer(e.tail) if e.tail is not None else T_UNIT
        self.pop_scope()
        e.ty = ty
        return ty

    def infer_if(self, e):
        self.check(e.cond, T_BOOL)
        if e.els is None:
            self.check(e.then, T_UNIT)
            e.ty = T_UNIT
            return T_UNIT
        if not diverges_expr(e.then):
            t = self.infer(e.then)
            self.check(e.els, t)
            e.ty = t
            return t
        self.infer(e.then)
        if not diverges_expr(e.els):
            t = self.infer(e.els)
            e.ty = t
            return t
        self.infer(e.els)
        e.ty = T_UNIT
        return T_UNIT

    def infer_match(self, e):
        return self.match_expr(e, None)

    def infer_lambda(self, e):
        for p in e.params:
            if p.ann is None:
                raise CompileError('cannot-infer', p.line, p.col)
        ptypes = [resolve_type(self.tyctx, p.ann) for p in e.params]
        ret = (resolve_type(self.tyctx, e.ret) if e.ret is not None else None)
        got = self.lambda_body(e, ptypes, ret)
        e.ty = TFn(ptypes, got)
        return e.ty

    def lambda_body(self, e, ptypes, ret):
        """Check a lambda's body; returns its return type."""
        f = self.new_func(self.func, ret, 'lambda', '<lambda>')
        f.node = e
        e.info = f
        outer = self.func
        self.func = f
        self.push_scope()
        names = {}
        for p, t in zip(e.params, ptypes):
            if p.name in names:
                raise CompileError('dup-name', p.line, p.col)
            names[p.name] = True
            p.bind = self.declare(p.name, t, False)
        f.nparams = len(e.params)
        if type(e.body) is EBlock:
            if ret is None:
                got = self.infer_block(e.body)
                f.ret = got
            else:
                self.check_fn_body(e.body, ret, e.line, e.col)
                got = ret
        else:
            if ret is None:
                got = self.infer(e.body)
                f.ret = got
            else:
                self.check(e.body, ret)
                got = ret
        self.pop_scope()
        self.func = outer
        return got

    # -- expressions: checking --------------------------------------------

    def check(self, e, want):
        k = type(e)
        if k is EList:
            return self.check_list(e, want)
        if k is EMap:
            return self.check_map(e, want)
        if k is ETuple:
            return self.check_tuple(e, want)
        if k is ELambda:
            return self.check_lambda(e, want)
        if k is EIf:
            return self.check_if(e, want)
        if k is EMatch:
            return self.match_expr(e, want)
        if k is EBlock:
            return self.check_block(e, want)
        if k is ECall:
            return self.call(e, want)
        if k is EStructLit:
            return self.struct_lit(e, want)
        if k is EPath:
            res = self.resolve_value(e)
            if res[0] == 'variant0':
                return self.call_variant(e, res[1], [], want, e)
            if res[0] != 'local':
                raise CompileError('bad-value-ref', e.nline, e.ncol)
            b = res[1]
            e.res = self.access(b)
            e.ty = b.ty
            if not unify(want, b.ty):
                raise CompileError('type-mismatch', e.line, e.col)
            return b.ty
        got = self.infer(e)
        if not unify(want, got):
            raise CompileError('type-mismatch', e.line, e.col)
        return got

    def check_list(self, e, want):
        w = prune(want)
        if type(w) is TVar:
            elem = self.new_var()
            w.sol = TList(elem)
        else:
            if type(w) is not TList:
                raise CompileError('type-mismatch', e.line, e.col)
            elem = w.elem
        for x in e.elems:
            self.check(x, elem)
        e.ty = TList(elem)
        return e.ty

    def check_map(self, e, want):
        w = prune(want)
        if type(w) is TVar:
            kt = self.new_var()
            vt = self.new_var()
            w.sol = TMap(kt, vt)
        else:
            if type(w) is not TMap:
                raise CompileError('type-mismatch', e.line, e.col)
            kt = w.key
            vt = w.val
        for k, v in e.entries:
            self.check(k, kt)
            self.check(v, vt)
        if is_ground(kt) and not holds_key(kt):
            raise CompileError('bad-key-type', e.line, e.col)
        e.ty = TMap(kt, vt)
        return e.ty

    def check_tuple(self, e, want):
        n = len(e.parts)
        if n > 8:
            raise CompileError('bad-arity', e.line, e.col)
        w = prune(want)
        if type(w) is TVar:
            parts = [self.new_var() for _ in range(n)]
            w.sol = TTuple(parts)
        else:
            if type(w) is not TTuple or len(w.parts) != n:
                raise CompileError('type-mismatch', e.line, e.col)
            parts = list(w.parts)
        for p, t in zip(e.parts, parts):
            self.check(p, t)
        e.ty = TTuple(parts)
        return e.ty

    def check_lambda(self, e, want):
        w = prune(want)
        n = len(e.params)
        if type(w) is TVar:
            params = [self.new_var() for _ in range(n)]
            ret = self.new_var()
            w.sol = TFn(params, ret)
        else:
            if type(w) is not TFn:
                raise CompileError('type-mismatch', e.line, e.col)
            if len(w.params) != n:
                raise CompileError('type-mismatch', e.line, e.col)
            params = list(w.params)
            ret = w.ret
        ptypes = []
        for p, t in zip(e.params, params):
            if p.ann is not None:
                ann = resolve_type(self.tyctx, p.ann)
                if not unify(t, ann):
                    raise CompileError('type-mismatch', p.ann.line, p.ann.col)
            elif type(prune(t)) is TVar:
                raise CompileError('cannot-infer', p.line, p.col)
            ptypes.append(t)
        if e.ret is not None:
            ann = resolve_type(self.tyctx, e.ret)
            if not unify(ret, ann):
                raise CompileError('type-mismatch', e.ret.line, e.ret.col)
        self.lambda_body(e, ptypes, ret)
        e.ty = TFn(ptypes, ret)
        return e.ty

    def check_if(self, e, want):
        self.check(e.cond, T_BOOL)
        if e.els is None:
            if not unify(want, T_UNIT):
                raise CompileError('type-mismatch', e.line, e.col)
            self.check(e.then, T_UNIT)
            e.ty = T_UNIT
            return T_UNIT
        self.check(e.then, want)
        self.check(e.els, want)
        e.ty = want
        return want

    def check_block(self, e, want):
        self.push_scope()
        for s in e.stmts:
            self.stmt(s)
        if e.tail is not None:
            self.check(e.tail, want)
        elif not diverges_expr(e):
            if not unify(want, T_UNIT):
                raise CompileError('type-mismatch', e.line, e.col)
        self.pop_scope()
        e.ty = want
        return want

    # -- calls -----------------------------------------------------------

    def call(self, e, want):
        callee = e.callee
        if len(e.args) > 16:
            raise CompileError('bad-arity', callee.line, callee.col)
        if type(callee) is EPath:
            res = self.resolve_value(callee)
            tag = res[0]
            if tag == 'fn':
                it = res[1]
                e.res = ('fn', it)
                order, ptypes, ret = it.sig
                ty = self.call_generic(order, ptypes, ret, e.args, want,
                                       callee)
                e.ty = ty
                return ty
            if tag == 'builtin':
                name = res[1]
                e.res = ('builtin', BUILTIN_INDEX[name])
                order, ptypes, ret = BUILTIN_SIGS[name]
                ty = self.call_generic(order, ptypes, ret, e.args, want,
                                       callee)
                e.ty = ty
                return ty
            if tag == 'variant' or tag == 'variant0':
                ty = self.call_variant(e, res[1], e.args, want, callee)
                e.ty = ty
                return ty
            if tag == 'traitmethod':
                tr, meth = res[1], res[2]
                ty = self.trait_path_call(e, tr, meth, callee)
                if want is not None:
                    if not unify(want, ty):
                        raise CompileError('type-mismatch', e.line, e.col)
                e.ty = ty
                return ty
            if tag == 'local':
                b = res[1]
                callee.res = self.access(b)
                callee.ty = b.ty
                ty = self.indirect_call(e, b.ty, callee)
                if want is not None and not unify(want, ty):
                    raise CompileError('type-mismatch', e.line, e.col)
                e.ty = ty
                return ty
            raise CompileError('bad-value-ref', callee.nline, callee.ncol)
        fty = self.infer(callee)
        ty = self.indirect_call(e, fty, callee)
        if want is not None and not unify(want, ty):
            raise CompileError('type-mismatch', e.line, e.col)
        e.ty = ty
        return ty

    def indirect_call(self, e, fty, callee):
        fty = prune(fty)
        if type(fty) is not TFn:
            raise CompileError('not-callable', callee.line, callee.col)
        if len(e.args) != len(fty.params):
            raise CompileError('arity', callee.line, callee.col)
        e.res = ('indirect',)
        for a, t in zip(e.args, fty.params):
            self.check(a, t)
        return fty.ret

    def call_generic(self, tparams, ptypes, ret, args, want, cpos):
        if len(args) != len(ptypes):
            raise CompileError('arity', cpos.line, cpos.col)
        self.push_vars()
        mapping = {}
        for tp in tparams:
            mapping[tp] = self.new_var()
        for a, pt in zip(args, ptypes):
            self.check(a, subst(pt, mapping))
        out = subst(ret, mapping)
        if want is not None:
            if not unify(out, want):
                self.pop_vars()
                raise CompileError('type-mismatch', cpos.line, cpos.col)
        created = self.pop_vars()
        for v in created:
            if not is_ground(v):
                raise CompileError('cannot-infer', cpos.line, cpos.col)
        for tp in tparams:
            for b in tp.bounds:
                if not self.bound_holds(mapping[tp], b):
                    raise CompileError('unsatisfied-bound', cpos.line,
                                       cpos.col)
        return resolve(out)

    def call_variant(self, e, vd, args, want, cpos):
        enum = vd.enum
        ty = self.call_generic(enum.params, vd.payloads,
                               TNamed(enum, enum.params), args, want, cpos)
        if type(e) is ECall:
            e.res = ('variant', vd)
        else:
            e.res = ('variant', vd)
        e.ty = ty
        return ty

    def trait_path_call(self, e, tr, meth, cpos):
        if len(e.args) == 0:
            raise CompileError('arity', cpos.nline, cpos.ncol)
        recv = e.args[0]
        rest = e.args[1:]
        rty = self.infer(recv)
        return self.resolved_method(e, tr, meth, rty, rest, cpos.nline,
                                    cpos.ncol)

    def method_call(self, e):
        rty = self.infer(e.recv)
        cands = [t for t in self.traits_of_module() if e.name in t.mindex]
        if not cands:
            raise CompileError('no-method', e.nline, e.ncol)
        if len(cands) > 1:
            raise CompileError('ambig-method', e.nline, e.ncol)
        tr = cands[0]
        meth = tr.mindex[e.name]
        if len(e.args) > 16:
            raise CompileError('bad-arity', e.nline, e.ncol)
        return self.resolved_method(e, tr, meth, rty, e.args, e.nline, e.ncol)

    def resolved_method(self, e, tr, meth, rty, args, mline, mcol):
        ptypes, ret = meth.sig
        if len(args) != len(ptypes):
            raise CompileError('arity', mline, mcol)
        r = prune(rty)
        if type(r) is TParam:
            if tr not in r.bounds:
                raise CompileError('unsatisfied-bound', mline, mcol)
        else:
            if not self.satisfies(r, tr):
                raise CompileError('unsatisfied-bound', mline, mcol)
        mapping = {tr.self_param: r}
        for a, pt in zip(args, ptypes):
            self.check(a, subst(pt, mapping))
        e.res = ('method', tr, meth.index)
        out = resolve(subst(ret, mapping))
        e.ty = out
        return out

    # -- struct literals ---------------------------------------------------

    def struct_lit(self, e, want):
        path = e.path
        decl = self.resolve_type_path_for_value(path)
        if isinstance(decl, EnumDecl):
            raise CompileError('not-struct', path.line, path.col)
        self.push_vars()
        args = [self.new_var() for _ in decl.params]
        sty = TNamed(decl, args)
        if want is not None:
            if not unify(sty, want):
                self.pop_vars()
                raise CompileError('type-mismatch', path.line, path.col)
        seen = {}
        for name, line, col, _val in e.fields:
            if name in seen:
                raise CompileError('dup-field', line, col)
            seen[name] = True
            if name not in decl.findex:
                raise CompileError('unknown-field', line, col)
        mapping = dict(zip(decl.params, args))
        byname = {}
        for idx, (name, line, col, val) in enumerate(e.fields):
            byname[name] = (idx, val)
        perm = []
        for fi, f in enumerate(decl.fields):
            got = byname.get(f.name)
            if got is None:
                raise CompileError('missing-field', path.line, path.col)
            perm.append(got[0])
            self.check(got[1], subst(decl.ftypes[fi], mapping))
        created = self.pop_vars()
        for v in created:
            if not is_ground(v):
                raise CompileError('cannot-infer', path.line, path.col)
        e.decl = decl
        e.perm = perm
        e.ty = resolve(sty)
        return e.ty

    def resolve_type_path_for_value(self, path):
        """Resolve a struct-literal or struct-pattern path in the types
        namespace."""
        if path.mod is None:
            decl = self.module.types.get(path.name)
            if decl is None:
                if path.name == 'Option':
                    decl = self.prog.option
                elif path.name == 'Result':
                    decl = self.prog.result
            if decl is None:
                raise CompileError('unknown-type', path.line, path.col)
            return decl
        target = self.module.imports.get(path.mod)
        if target is None:
            raise CompileError('unknown-module', path.line, path.col)
        decl = target.types.get(path.name)
        if decl is None:
            raise CompileError('unknown-type', path.nline, path.ncol)
        if not decl.pub and target is not self.module:
            raise CompileError('not-public', path.nline, path.ncol)
        return decl

    # -- match -------------------------------------------------------------

    def match_expr(self, e, want):
        sty = resolve(self.infer(e.scrut))
        if not e.arms:
            raise CompileError('non-exhaustive', e.line, e.col)
        rty = want
        for arm in e.arms:
            self.push_scope()
            self.pattern(arm.pat, sty, {})
            if arm.guard is not None:
                self.check(arm.guard, T_BOOL)
            if want is not None:
                self.check(arm.body, want)
            else:
                if rty is None and not diverges_expr(arm.body):
                    rty = self.infer(arm.body)
                elif rty is None:
                    self.infer(arm.body)
                else:
                    self.check(arm.body, rty)
            self.pop_scope()
        rows = []
        for arm in e.arms:
            if useful(rows, [arm.pat], [sty]) is False:
                raise CompileError('unreachable', arm.pat.line, arm.pat.col)
            if arm.guard is None:
                rows.append([arm.pat])
        if useful(rows, [WILD], [sty]):
            raise CompileError('non-exhaustive', e.line, e.col)
        if rty is None:
            rty = T_UNIT
        e.ty = rty
        return rty

    # -- patterns ----------------------------------------------------------

    def pattern(self, p, ty, names):
        k = type(p)
        ty = prune(ty)
        if k is PWild:
            return
        if k is PFloat:
            raise CompileError('bad-pattern', p.line, p.col)
        if k is PInt:
            if not is_prim(ty, 'Int'):
                raise CompileError('type-mismatch', p.line, p.col)
            return
        if k is PStr:
            if not is_prim(ty, 'Str'):
                raise CompileError('type-mismatch', p.line, p.col)
            return
        if k is PChar:
            if not is_prim(ty, 'Char'):
                raise CompileError('type-mismatch', p.line, p.col)
            return
        if k is PBool:
            if not is_prim(ty, 'Bool'):
                raise CompileError('type-mismatch', p.line, p.col)
            return
        if k is PBind:
            self.bind_name(p, p.name, ty, names)
            return
        if k is PVariant:
            if p.mod is None and p.subs is None:
                vd = self.zero_variant(p.name)
                if vd is None:
                    self.bind_name(p, p.name, ty, names)
                    return
                p.vd = vd
            else:
                p.vd = self.resolve_variant(p)
            vd = p.vd
            if type(ty) is not TNamed or ty.decl is not vd.enum:
                raise CompileError('type-mismatch', p.line, p.col)
            subs = p.subs or ()
            if len(subs) != len(vd.payloads):
                raise CompileError('arity', p.line, p.col)
            mapping = dict(zip(vd.enum.params, ty.args))
            for sub, pt in zip(subs, vd.payloads):
                self.pattern(sub, subst(pt, mapping), names)
            return
        if k is PStruct:
            decl = self.resolve_type_path_for_pattern(p)
            if not isinstance(decl, StructDecl):
                raise CompileError('not-struct', p.line, p.col)
            if type(ty) is not TNamed or ty.decl is not decl:
                raise CompileError('type-mismatch', p.line, p.col)
            p.decl = decl
            seen = {}
            for name, line, col, _sub in p.fields:
                if name in seen:
                    raise CompileError('dup-field', line, col)
                seen[name] = True
                if name not in decl.findex:
                    raise CompileError('unknown-field', line, col)
            if not p.rest and len(seen) != len(decl.fields):
                raise CompileError('missing-field', p.line, p.col)
            mapping = dict(zip(decl.params, ty.args))
            order = []
            newfields = []
            for name, line, col, sub in p.fields:
                idx = decl.findex[name]
                if sub is None:
                    sub = PBind(line, col, name, None)
                newfields.append((name, line, col, sub))
                order.append((idx, sub))
                self.pattern(sub, subst(decl.ftypes[idx], mapping), names)
            p.fields = newfields
            p.order = order
            return
        if k is PTuple:
            if type(ty) is not TTuple or len(ty.parts) != len(p.parts):
                raise CompileError('type-mismatch', p.line, p.col)
            for sub, t in zip(p.parts, ty.parts):
                self.pattern(sub, t, names)
            return
        if k is PList:
            if type(ty) is not TList:
                raise CompileError('type-mismatch', p.line, p.col)
            for sub in p.elems:
                self.pattern(sub, ty.elem, names)
            if p.restname is not None:
                p.restbind = self.bind_only(p, p.restname, TList(ty.elem),
                                            names)
            return
        raise AssertionError('bad pattern')

    def bind_name(self, p, name, ty, names):
        if name in names:
            raise CompileError('dup-name', p.line, p.col)
        names[name] = True
        b = self.declare(name, ty, False)
        p.bind = b
        return b

    def bind_only(self, p, name, ty, names):
        if name in names:
            raise CompileError('dup-name', p.line, p.col)
        names[name] = True
        return self.declare(name, ty, False)

    def zero_variant(self, name):
        """A bare identifier pattern is a variant only when the name resolves
        to a zero-payload variant (locals are not consulted)."""
        ent = self.module.values.get(name)
        if ent is None:
            for enum in (self.prog.option, self.prog.result):
                vd = enum.vindex.get(name)
                if vd is not None and not vd.payloads:
                    return vd
            return None
        if ent[0] != 'variant':
            return None
        vd = ent[1]
        return vd if not vd.payloads else None

    def resolve_variant(self, p):
        if p.mod is None:
            ent = self.module.values.get(p.name)
            if ent is None:
                for enum in (self.prog.option, self.prog.result):
                    vd = enum.vindex.get(p.name)
                    if vd is not None:
                        return vd
                raise CompileError('unknown-name', p.line, p.col)
            if ent[0] != 'variant':
                raise CompileError('type-mismatch', p.line, p.col)
            return ent[1]
        target = self.module.imports.get(p.mod)
        if target is None:
            raise CompileError('unknown-module', p.line, p.col)
        ent = target.values.get(p.name)
        if ent is None:
            raise CompileError('unknown-name', p.line, p.col)
        if ent[0] != 'variant':
            raise CompileError('type-mismatch', p.line, p.col)
        vd = ent[1]
        if not vd.enum.pub and target is not self.module:
            raise CompileError('not-public', p.line, p.col)
        return vd

    def resolve_type_path_for_pattern(self, p):
        if p.mod is None:
            decl = self.module.types.get(p.name)
            if decl is None:
                if p.name == 'Option':
                    decl = self.prog.option
                elif p.name == 'Result':
                    decl = self.prog.result
            if decl is None:
                raise CompileError('unknown-type', p.line, p.col)
            return decl
        target = self.module.imports.get(p.mod)
        if target is None:
            raise CompileError('unknown-module', p.line, p.col)
        decl = target.types.get(p.name)
        if decl is None:
            raise CompileError('unknown-type', p.line, p.col)
        if not decl.pub and target is not self.module:
            raise CompileError('not-public', p.line, p.col)
        return decl


def irrefutable(p):
    k = type(p)
    if k is PWild or k is PBind:
        return True
    if k is PVariant:
        if p.bind is not None:
            return True
        if len(p.vd.enum.variants) != 1:
            return False
        return all(irrefutable(s) for s in (p.subs or ()))
    if k is PStruct:
        return all(irrefutable(s) for _n, _l, _c, s in p.fields)
    if k is PTuple:
        return all(irrefutable(s) for s in p.parts)
    if k is PList:
        return p.rest and not p.elems
    return False


def check_program(prog):
    c = Checker(prog)
    c.run()
    return c
