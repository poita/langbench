"""The type checker (pass 4; SPEC sections 8-12).

Bidirectional checking with unification over inference variables.  It annotates
the syntax tree (resolved names, operator tags, captured variables, static
dispatch targets) so that the bytecode compiler never has to look anything up
by name.
"""

from __future__ import annotations

from . import syntax as S
from .diagnostics import error
from .patterns import first_unreachable, irrefutable, is_exhaustive
from .program import BuiltinInfo, FuncInfo, Program, VariantInfo, head_key_of
from .resolve import Resolver, Scope
from .traits import holds, is_eq, is_key, is_ord
from .types import (
    BOOL, CHAR, FLOAT, INT, PRIMS, STR, UNIT, TFn, TList, TMap, TNamed, TParam, TPrim,
    TTuple, TVar, Type, prune, subst, unify,
)


class LocalVar:
    """A local binding (parameter, let/var, pattern variable, loop variable)."""

    __slots__ = ("name", "ty", "mutable", "ctx", "slot")

    def __init__(self, name: str, ty: Type, mutable: bool, ctx: "FnCtx"):
        self.name = name
        self.ty = ty
        self.mutable = mutable
        self.ctx = ctx
        self.slot = -1


class FnCtx:
    """Per-function (or lambda) checking state; later read by the compiler."""

    def __init__(self, parent: "FnCtx | None", ret: Type | None):
        self.parent = parent
        self.ret = ret
        self.loop_depth = 0
        self.captures: dict[LocalVar, int] = {}
        self.self_var: LocalVar | None = None
        self.param_vars: list[LocalVar] = []


class Checker:
    def __init__(self, program: Program, resolver: Resolver):
        self.p = program
        self.resolver = resolver
        self.module = None
        self.scopes: list[dict] = []
        self.ctx: FnCtx | None = None
        self.tparams: dict[str, TParam] = {}
        self.self_ty: Type | None = None
        self.owners: list[list[TVar]] = []
        self.div_cache: dict[int, bool] = {}
        self.compile_order: list[FuncInfo] = []
        self.lambdas: list = []

    # ================================================================ driver
    def run(self) -> None:
        for m in self.p.modules:
            self.module = m
            for item in m.items:
                c = type(item)
                if c is S.TraitDecl:
                    trait = m.decls[id(item)]
                    for ms in trait.methods:
                        if ms.default is not None:
                            self.check_function(ms.default, {}, trait.self_param)
                elif c is S.ImplDecl:
                    impl = m.decls[id(item)]
                    tmap = {tp.name: tp for tp in impl.tparams}
                    for md in item.methods:
                        self.check_function(m.decls[id(md)], tmap, impl.head)
                elif c is S.FnDecl:
                    f = m.decls[id(item)]
                    self.check_function(f, {tp.name: tp for tp in f.tparams}, None)

    def check_function(self, f: FuncInfo, tmap: dict, self_ty) -> None:
        self.tparams = tmap
        self.self_ty = self_ty
        ctx = FnCtx(None, f.ret)
        f.ctx = ctx
        self.ctx = ctx
        self.scopes = [{}]
        if f.kind in ("method", "default"):
            sv = LocalVar("self", self_ty, False, ctx)
            ctx.self_var = sv
            ctx.param_vars.append(sv)
        for (name, ty) in f.params:
            v = LocalVar(name, ty, False, ctx)
            ctx.param_vars.append(v)
            self.scopes[0][name] = v
        self.check_body(f.node.body, f.ret, f.node.pos)
        self.compile_order.append(f)
        self.ctx = None

    # ============================================================== helpers
    def err(self, kind: str, pos):
        return error(kind, pos)

    def fresh(self) -> TVar:
        v = TVar()
        if self.owners:
            self.owners[-1].append(v)
        return v

    def push_scope(self) -> None:
        self.scopes.append({})

    def pop_scope(self) -> None:
        self.scopes.pop()

    def declare(self, v: LocalVar) -> None:
        self.scopes[-1][v.name] = v

    def lookup_local(self, name: str):
        for sc in reversed(self.scopes):
            v = sc.get(name)
            if v is not None:
                return v
        return None

    def use_var(self, v: LocalVar) -> None:
        c = self.ctx
        while c is not v.ctx:
            if v not in c.captures:
                c.captures[v] = len(c.captures)
            c = c.parent

    def resolve_type(self, t):
        return self.resolver.resolve_type(t, Scope(self.module, self.tparams, self.self_ty))

    def mismatch(self, pos):
        return error("type-mismatch", pos)

    def diverges(self, n) -> bool:
        if n is None:
            return False
        key = id(n)
        r = self.div_cache.get(key)
        if r is not None:
            return r
        c = type(n)
        if c in (S.Return, S.Break, S.Continue):
            r = True
        elif c is S.Let or c is S.VarDecl or c is S.Assign:
            r = self.diverges(n.expr)
        elif c is S.ExprStmt:
            r = self.diverges(n.expr)
        elif c is S.Block:
            r = any(self.diverges(s) for s in n.stmts) or self.diverges(n.tail)
        elif c is S.If:
            r = n.els is not None and self.diverges(n.then) and self.diverges(n.els)
        elif c is S.Match:
            r = bool(n.arms) and all(self.diverges(a.body) for a in n.arms)
        else:
            r = False
        self.div_cache[key] = r
        return r

    # ============================================================== bodies
    def check_body(self, body, ret: Type | None, missing_pos) -> Type | None:
        """Function/lambda body rule (11.6).  ``ret`` None = synthesise (lambdas)."""
        if type(body) is not S.Block:
            if ret is None:
                return self.infer(body)
            self.check(body, ret)
            return ret
        self.push_scope()
        for s in body.stmts:
            self.stmt(s)
        result = ret
        if body.tail is not None:
            if ret is None:
                result = self.infer(body.tail)
            else:
                self.check(body.tail, ret)
        else:
            if ret is None:
                result = UNIT
            elif prune(ret) is not UNIT and not self.diverges(body):
                raise self.err("missing-return", missing_pos)
        self.pop_scope()
        return result

    # ============================================================ statements
    def stmt(self, s) -> None:
        c = type(s)
        if c is S.ExprStmt:
            self.infer(s.expr)
        elif c is S.Let:
            self.stmt_let(s)
        elif c is S.VarDecl:
            if s.ty is not None:
                t = self.resolve_type(s.ty)
                self.check(s.expr, t)
            else:
                t = self.infer(s.expr)
            v = LocalVar(s.name, t, True, self.ctx)
            s.var = v
            self.declare(v)
        elif c is S.Assign:
            self.stmt_assign(s)
        elif c is S.Return:
            self.stmt_return(s)
        elif c is S.While:
            self.check(s.cond, BOOL)
            self.loop_body(s.body, [])
        elif c is S.For:
            self.stmt_for(s)
        elif c is S.Break or c is S.Continue:
            if self.ctx.loop_depth == 0:
                raise self.err("break-outside", s.pos)
        else:
            raise AssertionError(s)

    def stmt_let(self, s: S.Let) -> None:
        if s.ty is not None:
            t = self.resolve_type(s.ty)
            self.check(s.expr, t)
        else:
            t = self.infer(s.expr)
        vars_: list[LocalVar] = []
        self.pattern(s.pat, t, {}, vars_)
        if not irrefutable(s.pat):
            raise self.err("refutable-pattern", s.pat.pos)
        for v in vars_:
            self.declare(v)

    def stmt_return(self, s: S.Return) -> None:
        ret = self.ctx.ret
        if ret is None:
            raise self.err("cannot-infer", s.pos)
        r = prune(ret)
        if s.expr is None:
            if r is UNIT:
                return
            if type(r) is TVar:
                unify(r, UNIT)
                return
            raise self.mismatch(s.pos)
        if r is UNIT:
            t = self.infer(s.expr)
            if prune(t) is not UNIT:
                raise self.mismatch(s.pos)
            return
        self.check(s.expr, ret)

    def stmt_assign(self, s: S.Assign) -> None:
        t = s.target
        c = type(t)
        if c is S.PathExpr and t.qual is None:
            v = self.lookup_local(t.name)
            if v is None:
                raise self.err("unknown-name", t.pos)
            if not v.mutable:
                raise self.err("assign-immutable", t.pos)
            if v.ctx is not self.ctx:
                raise self.err("assign-captured", t.pos)
            s.var = v
            s.tag = "local"
            self.check(s.expr, v.ty)
        elif c is S.Index:
            a = prune(self.infer(t.base))
            if type(a) is TList:
                self.check(t.index, INT)
                self.check(s.expr, a.elem)
                s.tag = "list"
            elif type(a) is TMap:
                self.check(t.index, a.key)
                self.check(s.expr, a.val)
                s.tag = "map"
            else:
                raise self.err("bad-target", t.base.pos)
        else:
            raise self.err("bad-target", t.pos)

    def loop_body(self, body: S.Block, vars_) -> None:
        self.ctx.loop_depth += 1
        self.push_scope()
        for v in vars_:
            self.declare(v)
        for st in body.stmts:
            self.stmt(st)
        if body.tail is not None:
            self.infer(body.tail)
        self.pop_scope()
        self.ctx.loop_depth -= 1

    def stmt_for(self, s: S.For) -> None:
        vars_: list[LocalVar] = []
        if s.hi is not None:
            self.check(s.iter, INT)
            self.check(s.hi, INT)
            s.tag = "range"
            self.pattern(s.pat, INT, {}, vars_)
        else:
            t = prune(self.infer(s.iter))
            if type(t) is TList:
                s.tag = "list"
                self.pattern(s.pat, t.elem, {}, vars_)
            elif t is STR:
                s.tag = "str"
                self.pattern(s.pat, CHAR, {}, vars_)
            else:
                raise self.err("not-iterable", s.iter.pos)
        if not irrefutable(s.pat):
            raise self.err("refutable-pattern", s.pat.pos)
        self.loop_body(s.body, vars_)

    # ============================================================== dispatch
    def infer(self, e) -> Type:
        return self._INFER[type(e)](self, e)

    def check(self, e, t: Type) -> None:
        f = self._CHECK.get(type(e))
        if f is not None:
            f(self, e, t)
            return
        s = self.infer(e)
        if not unify(t, s):
            raise self.mismatch(e.pos)

    # ============================================================== literals
    def i_int(self, e):
        return INT

    def i_float(self, e):
        return FLOAT

    def i_str(self, e):
        return STR

    def i_char(self, e):
        return CHAR

    def i_bool(self, e):
        return BOOL

    def i_self(self, e: S.SelfExpr):
        c = self.ctx
        while c.parent is not None:
            c = c.parent
        v = c.self_var
        if v is None:
            raise self.err("self-outside", e.pos)
        self.use_var(v)
        e.var = v
        return v.ty

    # ================================================================= paths
    def resolve_value(self, e: S.PathExpr):
        """Resolve a value path to ``(kind, thing[, extra])`` (section 5.4 / 10.2)."""
        if e.qual is None:
            name = e.name
            v = self.lookup_local(name)
            if v is not None:
                return ("local", v)
            x = self.module.values.get(name)
            if x is None:
                x = self.p.prelude.values.get(name)
            if x is not None:
                return (self._kind(x), x)
            if (
                name in self.module.types
                or name in self.p.prelude.types
                or name in PRIMS
                or name == "Self"
            ):
                return ("type", None)
            raise self.err("unknown-name", e.name_pos)
        mod = self.module.imports.get(e.qual)
        if mod is not None:
            x = mod.values.get(e.name)
            if x is None:
                raise self.err("unknown-name", e.name_pos)
            pub = x.pub if isinstance(x, FuncInfo) else x.enum.pub
            if not pub and mod is not self.module:
                raise self.err("not-public", e.name_pos)
            return (self._kind(x), x)
        trait = self.resolver.find_trait_by_name(self.module, e.qual)
        if trait is not None:
            ms = trait.method_index.get(e.name)
            if ms is None:
                raise self.err("unknown-name", e.name_pos)
            return ("traitmethod", ms)
        raise self.err("unknown-module", e.qual_pos)

    @staticmethod
    def _kind(x) -> str:
        if isinstance(x, FuncInfo):
            return "func"
        if isinstance(x, BuiltinInfo):
            return "builtin"
        return "variant"

    def i_path(self, e: S.PathExpr):
        return self.path_value(e, None)

    def c_path(self, e: S.PathExpr, t):
        self.path_value(e, t)

    def path_value(self, e: S.PathExpr, expected):
        res = self.resolve_value(e)
        kind = res[0]
        e.res = res
        if kind == "local":
            v = res[1]
            self.use_var(v)
            ty = v.ty
        elif kind == "variant" and not res[1].payload:
            vi = res[1]
            ty = self.instantiate(
                vi.enum.tparams, [], vi.enum.own_type(), [], expected, e.pos, e.pos
            )
            return ty
        else:
            raise self.err("bad-value-ref", e.name_pos)
        if expected is not None and not unify(expected, ty):
            raise self.mismatch(e.pos)
        return ty

    # ------------------------------------------------------- generic calls
    def instantiate(self, tparams, params, ret, args, expected, callee_pos, call_pos):
        """The generic-call rule of section 9.4; returns the call's type."""
        if len(args) != len(params):
            raise self.err("arity", callee_pos)
        owner: list[TVar] = []
        self.owners.append(owner)
        try:
            m = {tp: self.fresh() for tp in tparams}
            for a, p in zip(args, params):
                self.check(a, subst(p, m))
            result = subst(ret, m)
            if expected is not None and not unify(result, expected):
                raise self.mismatch(call_pos)
            for v in owner:
                if type(prune(v)) is TVar:
                    raise self.err("cannot-infer", callee_pos)
            for tp in tparams:
                if tp.bounds:
                    arg = m[tp]
                    for b in tp.bounds:
                        if not holds(self.p, arg, b):
                            raise self.err("unsatisfied-bound", callee_pos)
        finally:
            self.owners.pop()
        return result

    def i_call(self, e: S.Call):
        return self.call(e, None)

    def c_call(self, e: S.Call, t):
        self.call(e, t)

    def call(self, e: S.Call, expected):
        callee = e.callee
        args = e.args
        if len(args) > 16:
            raise self.err("bad-arity", callee.pos)
        if type(callee) is S.PathExpr:
            res = self.resolve_value(callee)
            kind = res[0]
            if kind in ("func", "builtin", "variant"):
                x = res[1]
                e.kind = kind
                e.target = x
                if kind == "func":
                    return self.instantiate(
                        x.tparams, [t for _, t in x.params], x.ret, args, expected, e.pos, e.pos
                    )
                if kind == "builtin":
                    return self.instantiate(x.tparams, x.params, x.ret, args, expected, e.pos, e.pos)
                return self.instantiate(
                    x.enum.tparams, x.payload, x.enum.own_type(), args, expected, e.pos, e.pos
                )
            if kind == "traitmethod":
                ms = res[1]
                if not args:
                    raise self.err("arity", callee.name_pos)
                e.kind = "method"
                ty = self.method_common(e, ms, callee.name_pos, args[0], args[1:], True)
                return self.finish(ty, expected, e.pos)
            if kind == "type":
                raise self.err("bad-value-ref", callee.name_pos)
            f = self.path_value(callee, None)
        else:
            f = self.infer(callee)
        f = prune(f)
        if type(f) is not TFn:
            raise self.err("not-callable", callee.pos)
        if len(f.params) != len(args):
            raise self.err("arity", callee.pos)
        for a, p in zip(args, f.params):
            self.check(a, p)
        e.kind = "value"
        return self.finish(f.ret, expected, e.pos)

    def finish(self, ty, expected, pos):
        if expected is not None and not unify(expected, ty):
            raise self.mismatch(pos)
        return ty

    # ------------------------------------------------------------- methods
    def i_method(self, e: S.MethodCall):
        return self.method_call(e, None)

    def c_method(self, e: S.MethodCall, t):
        self.method_call(e, t)

    def method_call(self, e: S.MethodCall, expected):
        if len(e.args) > 16:
            raise self.err("bad-arity", e.name_pos)
        cands = [
            tr.method_index[e.name]
            for tr in self.module.visible_traits()
            if e.name in tr.method_index
        ]
        # recv is checked before candidates are examined (section 8.5 step 1)
        recv_ty = self.infer(e.recv)
        if not cands:
            raise self.err("no-method", e.name_pos)
        if len(cands) > 1:
            raise self.err("ambig-method", e.name_pos)
        ty = self.method_with(e, cands[0], e.name_pos, recv_ty, e.args, False)
        return self.finish(ty, expected, e.pos)

    def method_common(self, e, ms, name_pos, recv, args, path_form):
        """Shared by ``recv.m(..)`` (already typed) and ``Tr::m(recv, ..)``."""
        recv_ty = self.infer(recv)
        return self.method_with(e, ms, name_pos, recv_ty, args, path_form)

    def method_with(self, e, ms, name_pos, recv_ty, args, path_form):
        trait = ms.trait
        if len(args) != len(ms.params):
            raise self.err("arity", name_pos)
        r = prune(recv_ty)
        if type(r) is TParam:
            if trait not in r.bounds:
                raise self.err("unsatisfied-bound", name_pos)
            target = None
        else:
            if not holds(self.p, r, trait):
                raise self.err("unsatisfied-bound", name_pos)
            impl = self.p.impls[(trait.uid, head_key_of(r))]
            target = impl.methods.get(ms.name) or ms.default
        m = {trait.self_param: r}
        for a, p in zip(args, ms.params):
            self.check(a, subst(p, m))
        if type(e) is S.MethodCall:
            e.midx = ms.index
            e.target = target
            e.trait = trait
            e.path_form = False
        else:
            e.target = (trait, ms, target)
        return subst(ms.ret, m)

    # ================================================================ fields
    def i_field(self, e: S.FieldAccess):
        t = prune(self.infer(e.obj))
        if type(t) is not TNamed or t.decl.is_enum:
            raise self.err("not-struct", e.obj.pos)
        decl = t.decl
        idx = decl.field_index.get(e.name)
        if idx is None:
            raise self.err("unknown-field", e.name_pos)
        e.index = idx
        return subst(decl.fields[idx][1], dict(zip(decl.tparams, t.args)))

    def i_index(self, e: S.Index):
        a = prune(self.infer(e.base))
        if type(a) is TList:
            self.check(e.index, INT)
            e.tag = "list"
            return a.elem
        if a is STR:
            self.check(e.index, INT)
            e.tag = "str"
            return CHAR
        if type(a) is TMap:
            self.check(e.index, a.key)
            e.tag = "map"
            return a.val
        raise self.err("not-indexable", e.base.pos)

    # ============================================================== operators
    def i_unary(self, e: S.Unary):
        op = e.op
        if op == "-":
            t = prune(self.infer(e.operand))
            if t is INT:
                e.tag = "int"
            elif t is FLOAT:
                e.tag = "float"
            else:
                raise self.mismatch(e.operand.pos)
            return t
        if op == "!":
            self.check(e.operand, BOOL)
            return BOOL
        self.check(e.operand, INT)
        return INT

    def i_binary(self, e: S.Binary):
        op = e.op
        if op in ("+", "-", "*", "/", "%"):
            l = prune(self.infer(e.left))
            if l is INT:
                e.tag = "int"
            elif l is FLOAT and op != "%":
                e.tag = "float"
            else:
                raise self.mismatch(e.left.pos)
            self.check(e.right, l)
            return l
        if op == "++":
            l = prune(self.infer(e.left))
            if l is STR:
                e.tag = "str"
            elif type(l) is TList:
                e.tag = "list"
            else:
                raise self.mismatch(e.left.pos)
            self.check(e.right, l)
            return l
        if op in ("&", "|", "^", "<<", ">>"):
            self.check(e.left, INT)
            self.check(e.right, INT)
            return INT
        if op in ("<", "<=", ">", ">="):
            l = self.infer(e.left)
            if not is_ord(l):
                raise self.err("not-ord", e.left.pos)
            self.check(e.right, l)
            return BOOL
        if op in ("==", "!="):
            l = self.infer(e.left)
            if not is_eq(l):
                raise self.err("not-eq", e.left.pos)
            e.tag = "deep" if needs_deep_eq(l) else "eq"
            self.check(e.right, l)
            return BOOL
        # && ||
        self.check(e.left, BOOL)
        self.check(e.right, BOOL)
        return BOOL

    # ================================================================ literals
    def i_list(self, e: S.ListLit):
        if not e.items:
            raise self.err("cannot-infer", e.pos)
        t = self.infer(e.items[0])
        for x in e.items[1:]:
            self.check(x, t)
        return TList(t)

    def c_list(self, e: S.ListLit, t):
        t = prune(t)
        if type(t) is TVar:
            nt = TList(self.fresh())
            unify(t, nt)
            t = nt
        if type(t) is not TList:
            raise self.mismatch(e.pos)
        for x in e.items:
            self.check(x, t.elem)

    def i_map(self, e: S.MapLit):
        if not e.entries:
            raise self.err("cannot-infer", e.pos)
        k0, v0 = e.entries[0]
        k = self.infer(k0)
        if not is_key(k):
            raise self.err("bad-key-type", k0.pos)
        v = self.infer(v0)
        for ke, ve in e.entries[1:]:
            self.check(ke, k)
            self.check(ve, v)
        return TMap(k, v)

    def c_map(self, e: S.MapLit, t):
        t = prune(t)
        if type(t) is TVar:
            nt = TMap(self.fresh(), self.fresh())
            unify(t, nt)
            t = nt
        if type(t) is not TMap:
            raise self.mismatch(e.pos)
        for ke, ve in e.entries:
            self.check(ke, t.key)
            self.check(ve, t.val)
        k = prune(t.key)
        if type(k) is not TVar and not is_key(k):
            raise self.err("bad-key-type", e.pos)

    def i_tuple(self, e: S.TupleLit):
        if len(e.items) > 8:
            raise self.err("bad-arity", e.pos)
        return TTuple([self.infer(x) for x in e.items])

    def c_tuple(self, e: S.TupleLit, t):
        t = prune(t)
        n = len(e.items)
        if n > 8:
            raise self.err("bad-arity", e.pos)
        if type(t) is TVar:
            nt = TTuple([self.fresh() for _ in range(n)])
            unify(t, nt)
            t = nt
        if type(t) is not TTuple or len(t.items) != n:
            raise self.mismatch(e.pos)
        for x, ty in zip(e.items, t.items):
            self.check(x, ty)

    # ============================================================== structs
    def i_structlit(self, e: S.StructLit):
        return self.struct_lit(e, None)

    def c_structlit(self, e: S.StructLit, t):
        self.struct_lit(e, t)

    def lookup_struct(self, qual, qual_pos, name, name_pos, pos):
        """Resolve a type path that must name a struct; returns the declaration."""
        if qual is not None:
            mod = self.resolver.import_module(self.module, qual, qual_pos)
            decl = mod.types.get(name)
            if decl is None:
                raise self.err("unknown-type", name_pos)
            if not decl.pub and mod is not self.module:
                raise self.err("not-public", name_pos)
        else:
            if name in self.tparams:
                raise self.err("not-struct", pos)
            if name == "Self":
                st = prune(self.self_ty) if self.self_ty is not None else None
                if st is None:
                    raise self.err("self-outside", pos)
                if type(st) is TNamed:
                    decl = st.decl
                else:
                    raise self.err("not-struct", pos)
            elif name in PRIMS:
                raise self.err("not-struct", pos)
            else:
                decl = self.module.types.get(name) or self.p.prelude.types.get(name)
                if decl is None:
                    raise self.err("unknown-type", name_pos)
        if decl.is_enum:
            raise self.err("not-struct", pos)
        return decl

    def struct_lit(self, e: S.StructLit, expected):
        path = e.path
        decl = self.lookup_struct(path.qual, path.qual_pos, path.name, path.name_pos, path.pos)
        e.decl = decl
        owner: list[TVar] = []
        self.owners.append(owner)
        try:
            m = {tp: self.fresh() for tp in decl.tparams}
            ty = TNamed(decl, [m[tp] for tp in decl.tparams])
            if expected is not None and not unify(ty, expected):
                raise self.mismatch(path.pos)
            seen = set()
            for f in e.fields:
                if f.name in seen:
                    raise self.err("dup-field", f.pos)
                seen.add(f.name)
                if f.name not in decl.field_index:
                    raise self.err("unknown-field", f.pos)
            by_name = {f.name: f for f in e.fields}
            for name, fty in decl.fields:
                f = by_name.get(name)
                if f is None:
                    raise self.err("missing-field", path.pos)
                self.check(f.expr, subst(fty, m))
            for v in owner:
                if type(prune(v)) is TVar:
                    raise self.err("cannot-infer", path.pos)
        finally:
            self.owners.pop()
        order = [decl.field_index[f.name] for f in e.fields]
        e.perm = None if order == list(range(len(order))) else order
        return ty

    # ================================================================ lambdas
    def i_lambda(self, e: S.Lambda):
        return self.lambda_(e, None)

    def c_lambda(self, e: S.Lambda, t):
        self.lambda_(e, t)

    def lambda_(self, e: S.Lambda, expected):
        ptypes: list[Type] = []
        if expected is None:
            for p in e.params:
                if p.ty is None:
                    raise self.err("cannot-infer", p.pos)
                ptypes.append(self.resolve_type(p.ty))
            ret = None
            if e.ret is not None:
                ret = self.resolve_type(e.ret)
        else:
            t = prune(expected)
            n = len(e.params)
            if type(t) is TVar:
                nt = TFn([self.fresh() for _ in range(n)], self.fresh())
                unify(t, nt)
                t = nt
            if type(t) is not TFn or len(t.params) != n:
                raise self.mismatch(e.pos)
            for p, a in zip(e.params, t.params):
                if p.ty is not None:
                    ann = self.resolve_type(p.ty)
                    if not unify(a, ann):
                        raise self.mismatch(p.ty.pos)
                elif type(prune(a)) is TVar:
                    raise self.err("cannot-infer", p.pos)
                ptypes.append(a)
            ret = t.ret
            if e.ret is not None:
                rt = self.resolve_type(e.ret)
                if not unify(ret, rt):
                    raise self.mismatch(e.ret.pos)
        seen = set()
        for p in e.params:
            if p.name in seen:
                raise self.err("dup-name", p.pos)
            seen.add(p.name)
        ctx = FnCtx(self.ctx, ret)
        e.ctx = ctx
        saved = self.ctx
        self.ctx = ctx
        self.push_scope()
        for p, pt in zip(e.params, ptypes):
            v = LocalVar(p.name, pt, False, ctx)
            p.var = v
            ctx.param_vars.append(v)
            self.declare(v)
        try:
            result = self.check_body(e.body, ret, e.pos)
        finally:
            self.pop_scope()
            self.ctx = saved
        return TFn(ptypes, result if result is not None else UNIT)

    # ====================================================== if / match / block
    def i_block(self, b: S.Block):
        self.push_scope()
        for s in b.stmts:
            self.stmt(s)
        t = self.infer(b.tail) if b.tail is not None else UNIT
        self.pop_scope()
        return t

    def c_block(self, b: S.Block, t):
        self.push_scope()
        for s in b.stmts:
            self.stmt(s)
        if b.tail is not None:
            self.check(b.tail, t)
        elif not self.diverges(b):
            if not unify(t, UNIT):
                raise self.mismatch(b.pos)
        self.pop_scope()

    def i_if(self, e: S.If):
        self.check(e.cond, BOOL)
        if e.els is None:
            self.check(e.then, UNIT)
            return UNIT
        if not self.diverges(e.then):
            t = self.infer(e.then)
            self.check(e.els, t)
            return t
        self.infer(e.then)
        if self.diverges(e.els):
            self.infer(e.els)
            return UNIT
        return self.infer(e.els)

    def c_if(self, e: S.If, t):
        self.check(e.cond, BOOL)
        if e.els is None:
            if not unify(t, UNIT):
                raise self.mismatch(e.pos)
            self.check(e.then, UNIT)
            return
        self.check(e.then, t)
        self.check(e.els, t)

    def i_match(self, e: S.Match):
        return self.match(e, None)

    def c_match(self, e: S.Match, t):
        self.match(e, t)

    def match(self, e: S.Match, expected):
        st = self.infer(e.scrut)
        if not e.arms:
            raise self.err("non-exhaustive", e.pos)
        result = None
        for arm in e.arms:
            self.push_scope()
            vars_: list[LocalVar] = []
            self.pattern(arm.pat, st, {}, vars_)
            for v in vars_:
                self.declare(v)
            if arm.guard is not None:
                self.check(arm.guard, BOOL)
            if expected is not None:
                self.check(arm.body, expected)
            elif result is None:
                if self.diverges(arm.body):
                    self.infer(arm.body)
                else:
                    result = self.infer(arm.body)
            else:
                self.check(arm.body, result)
            self.pop_scope()
        un = first_unreachable(e.arms, st)
        if un is not None:
            raise self.err("unreachable", un.pat.pos)
        if not is_exhaustive(e.arms, st):
            raise self.err("non-exhaustive", e.pos)
        if expected is not None:
            return expected
        return result if result is not None else UNIT

    # ================================================================ patterns
    def pattern(self, p, t, names: dict, out: list) -> None:
        """Type pattern ``p`` against ``t`` (ground), collecting bindings in ``out``."""
        c = type(p)
        t = prune(t)
        if c is S.PWild:
            return
        if c is S.PBind:
            p.ty = t
            x = self.module.values.get(p.name)
            if x is None:
                x = self.p.prelude.values.get(p.name)
            if isinstance(x, VariantInfo) and not x.payload:
                p.variant = x
                self.variant_pattern_type(p, x, t, 0)
                return
            self.bind(p.name, p.pos, t, names, out, p)
            return
        if c is S.PLit:
            if p.kind == "float":
                raise self.err("bad-pattern", p.pos)
            want = {"int": INT, "str": STR, "char": CHAR, "bool": BOOL}[p.kind]
            if t is not want:
                raise self.mismatch(p.pos)
            p.ty = t
            return
        if c is S.PTuple:
            if type(t) is not TTuple or len(t.items) != len(p.items):
                raise self.mismatch(p.pos)
            p.ty = t
            for sp, st in zip(p.items, t.items):
                self.pattern(sp, st, names, out)
            return
        if c is S.PList:
            if type(t) is not TList:
                raise self.mismatch(p.pos)
            p.ty = t
            for sp in p.items:
                self.pattern(sp, t.elem, names, out)
            if p.rest_name is not None:
                v = self.new_var(p.rest_name, p.rest_pos, TList(t.elem), names, out)
                p.rest_var = v
            return
        if c is S.PVariant:
            v = self.resolve_variant_pattern(p)
            p.variant = v
            p.ty = t
            self.variant_pattern_type(p, v, t, len(p.args or ()))
            if p.args:
                m = dict(zip(v.enum.tparams, t.args))
                for sp, pt in zip(p.args, v.payload):
                    self.pattern(sp, subst(pt, m), names, out)
            return
        if c is S.PStruct:
            self.struct_pattern(p, t, names, out)
            return
        raise AssertionError(p)

    def variant_pattern_type(self, p, v: VariantInfo, t, nargs: int) -> None:
        if type(t) is not TNamed or t.decl is not v.enum:
            raise self.mismatch(p.pos)
        if nargs != len(v.payload):
            raise self.err("arity", p.pos)

    def new_var(self, name, pos, ty, names, out) -> LocalVar:
        if name in names:
            raise self.err("dup-name", pos)
        names[name] = True
        v = LocalVar(name, ty, False, self.ctx)
        out.append(v)
        return v

    def bind(self, name, pos, ty, names, out, p) -> None:
        p.var = self.new_var(name, pos, ty, names, out)

    def resolve_variant_pattern(self, p: S.PVariant) -> VariantInfo:
        if p.qual is None:
            x = self.module.values.get(p.name)
            if x is None:
                x = self.p.prelude.values.get(p.name)
            if x is None:
                raise self.err("unknown-name", p.name_pos)
        else:
            mod = self.module.imports.get(p.qual)
            if mod is not None:
                x = mod.values.get(p.name)
                if x is None:
                    raise self.err("unknown-name", p.name_pos)
                pub = x.pub if isinstance(x, FuncInfo) else x.enum.pub
                if not pub and mod is not self.module:
                    raise self.err("not-public", p.name_pos)
            else:
                tr = self.resolver.find_trait_by_name(self.module, p.qual)
                if tr is None:
                    raise self.err("unknown-module", p.qual_pos)
                if p.name not in tr.method_index:
                    raise self.err("unknown-name", p.name_pos)
                raise self.mismatch(p.pos)
        if not isinstance(x, VariantInfo):
            raise self.mismatch(p.pos)
        return x

    def struct_pattern(self, p: S.PStruct, t, names, out) -> None:
        decl = self.lookup_struct(p.qual, p.qual_pos, p.name, p.name_pos, p.pos)
        p.decl = decl
        if type(t) is not TNamed or t.decl is not decl:
            raise self.mismatch(p.pos)
        p.ty = t
        seen = set()
        for f in p.fields:
            if f.name in seen:
                raise self.err("dup-field", f.pos)
            seen.add(f.name)
            idx = decl.field_index.get(f.name)
            if idx is None:
                raise self.err("unknown-field", f.pos)
            f.index = idx
        if not p.rest and len(seen) != len(decl.fields):
            raise self.err("missing-field", p.pos)
        m = dict(zip(decl.tparams, t.args))
        for f in p.fields:
            fty = subst(decl.fields[f.index][1], m)
            if f.pat is None:
                f.var = self.new_var(f.name, f.pos, fty, names, out)
            else:
                self.pattern(f.pat, fty, names, out)

    _INFER: dict = {}
    _CHECK: dict = {}


def needs_deep_eq(t) -> bool:
    """Does Python's ``==`` fail to implement structural equality for this type?

    That is the case when a float may be inside (NaN identity shortcuts in
    container comparison) or when the type is still generic."""
    return _deep(t, set())


def _deep(t, seen) -> bool:
    t = prune(t)
    c = type(t)
    if c is TPrim:
        return t is FLOAT
    if c is TList:
        return _deep(t.elem, seen)
    if c is TMap:
        return _deep(t.val, seen)
    if c is TTuple:
        return any(_deep(x, seen) for x in t.items)
    if c is TNamed:
        if any(_deep(a, seen) for a in t.args):
            return True
        d = t.decl
        if d.uid in seen:
            return False
        seen.add(d.uid)
        if d.is_enum:
            return any(_deep(p, seen) for v in d.variants for p in v.payload)
        return any(_deep(f, seen) for _, f in d.fields)
    return True  # parameters, functions, variables


Checker._INFER = {
    S.IntLit: Checker.i_int,
    S.FloatLit: Checker.i_float,
    S.StrLit: Checker.i_str,
    S.CharLit: Checker.i_char,
    S.BoolLit: Checker.i_bool,
    S.SelfExpr: Checker.i_self,
    S.PathExpr: Checker.i_path,
    S.StructLit: Checker.i_structlit,
    S.Unary: Checker.i_unary,
    S.Binary: Checker.i_binary,
    S.Call: Checker.i_call,
    S.MethodCall: Checker.i_method,
    S.Index: Checker.i_index,
    S.FieldAccess: Checker.i_field,
    S.ListLit: Checker.i_list,
    S.MapLit: Checker.i_map,
    S.TupleLit: Checker.i_tuple,
    S.Lambda: Checker.i_lambda,
    S.If: Checker.i_if,
    S.Match: Checker.i_match,
    S.Block: Checker.i_block,
}
Checker._CHECK = {
    S.PathExpr: Checker.c_path,
    S.StructLit: Checker.c_structlit,
    S.Call: Checker.c_call,
    S.ListLit: Checker.c_list,
    S.MapLit: Checker.c_map,
    S.TupleLit: Checker.c_tuple,
    S.Lambda: Checker.c_lambda,
    S.If: Checker.c_if,
    S.Match: Checker.c_match,
    S.Block: Checker.c_block,
    S.MethodCall: Checker.c_method,
}
