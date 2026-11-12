"""Bytecode compiler (SPEC section 16): annotated syntax tree -> :class:`Code` objects."""

from __future__ import annotations

from . import ops as O
from . import syntax as S
from .checker import FnCtx, LocalVar
from .prelude import HIGHER_ORDER
from .program import FuncInfo, Program
from .values import Char


class Code:
    """A compiled function: its instructions and frame layout."""

    __slots__ = ("name", "nparams", "nlocals", "code", "pad")

    def __init__(self, name: str):
        self.name = name
        self.nparams = 0
        self.nlocals = 0
        self.code: list[tuple] = []
        self.pad: list = []

    def __repr__(self):
        return f"<Code {self.name}>"


class Image:
    """A whole compiled program, ready for the VM."""

    def __init__(self, main: Code, ctor_head: dict, tables: list):
        self.main = main
        self.ctor_head = ctor_head
        self.tables = tables


_BIN_INT = {"+": O.ADD, "-": O.SUB, "*": O.MUL, "/": O.DIV, "%": O.MOD}
_BIN_FLOAT = {"+": O.FADD, "-": O.FSUB, "*": O.FMUL, "/": O.FDIV}
_BITS = {"&": O.BAND, "|": O.BOR, "^": O.BXOR, "<<": O.SHL, ">>": O.SHR}
_CMP = {"<": O.LT, "<=": O.LE, ">": O.GT, ">=": O.GE}
_CMP_JUMP = {"<": O.JLT, "<=": O.JLE, ">": O.JGT, ">=": O.JGE}
_BINARY_OPS = frozenset(
    (O.ADD, O.SUB, O.MUL, O.DIV, O.MOD, O.FADD, O.FSUB, O.FMUL, O.FDIV, O.EQ, O.NE, O.DEQ,
     O.DNE, O.LT, O.LE, O.GT, O.GE, O.BAND, O.BOR, O.BXOR, O.SHL, O.SHR, O.CATS, O.CATL)
)


class Loop:
    __slots__ = ("sp", "breaks", "continues")

    def __init__(self, sp):
        self.sp = sp
        self.breaks: list[int] = []
        self.continues: list[int] = []


class FnBuilder:
    """Per-function code emission state."""

    def __init__(self, code: Code, ctx: FnCtx, nparams: int):
        self.code = code
        self.ctx = ctx
        self.out: list[list] = []
        self.sp = 0
        self.loops: list[Loop] = []
        self.nparams = nparams
        self.next_slot = nparams + len(ctx.captures)

    def new_slot(self) -> int:
        s = self.next_slot
        self.next_slot += 1
        return s


class Compiler:
    def __init__(self, program: Program):
        self.p = program
        self.fb: FnBuilder = None  # type: ignore[assignment]
        self.tables: dict[tuple, dict] = {}
        self.table_list: list[dict] = []

    # --------------------------------------------------------------- driver
    def compile(self, funcs: list[FuncInfo]) -> Image:
        for f in funcs:
            f.code = Code(f.name)
        ctor_head: dict[int, object] = {}
        for s in self.p.structs:
            ctor_head[s.uid] = s.uid
        for e in self.p.enums:
            for v in e.variants:
                ctor_head[v.uid] = e.uid
        # method tables: (trait, method index) -> {head key: Code}
        for impl in self.p.impl_list:
            for ms in impl.trait.methods:
                f = impl.methods.get(ms.name) or ms.default
                tbl = self.table_for(impl.trait.uid, ms.index)
                tbl[impl.head_key] = f.code
        for f in funcs:
            self.compile_function(f)
        return Image(self.p.main.code, ctor_head, self.table_list)

    def table_for(self, trait_uid: int, midx: int) -> dict:
        key = (trait_uid, midx)
        t = self.tables.get(key)
        if t is None:
            t = self.tables[key] = {}
            self.table_list.append(t)
        return t

    def compile_function(self, f: FuncInfo) -> None:
        ctx = f.ctx
        code = f.code
        nparams = len(ctx.param_vars)
        self.fb = FnBuilder(code, ctx, nparams)
        for i, v in enumerate(ctx.param_vars):
            v.slot = i
        self.body(f.node.body)
        self.finish(code, nparams, ctx)

    def finish(self, code: Code, nparams: int, ctx: FnCtx) -> None:
        fb = self.fb
        code.nparams = nparams
        code.nlocals = fb.next_slot
        code.code = [tuple(i) for i in fb.out]
        code.pad = [None] * (fb.next_slot - nparams - len(ctx.captures))

    def body(self, body) -> None:
        """Compile a function or lambda body, ending in a return."""
        if type(body) is S.Block:
            for s in body.stmts:
                self.stmt(s)
            if body.tail is not None:
                self.expr(body.tail)
            else:
                self.emit(O.CONST, None)
        else:
            self.expr(body)
        self.emit(O.RET)

    # -------------------------------------------------------------- emission
    def emit(self, op, a=0, b=0, c=0) -> int:
        fb = self.fb
        fb.out.append([op, a, b, c])
        sp = fb.sp
        if op in _BINARY_OPS:
            sp -= 1
        elif op == O.CONST or op == O.LOAD:
            sp += 1
        elif op == O.STORE or op == O.POP or op == O.JIF or op == O.JIT or op == O.JFK or op == O.JTK:
            sp -= 1
        elif op == O.POPN:
            sp -= a
        elif op == O.CALL or op == O.CALLB or op == O.CALLH:
            sp += 1 - b
        elif op == O.CALLV or op == O.CALLM:
            sp -= b
        elif op in (O.MKLIST, O.MKTUP, O.MKSTRUCT, O.MKENUM, O.MKCLOS):
            sp += 1 - b
        elif op == O.MKMAP:
            sp += 1 - 2 * a
        elif op == O.IDXL or op == O.IDXS or op == O.IDXM:
            sp -= 1
        elif op == O.SETL or op == O.SETM:
            sp -= 3
        elif op in (O.LOADFIELD, O.LOADTUP, O.LOADELEM, O.LISTREST):
            sp += 1
        elif op in (O.JLT, O.JLE, O.JGT, O.JGE, O.JEQ, O.JNE):
            sp -= 2
        elif op == O.FORLIST or op == O.FORSTR:
            if b == -1:
                sp += 1
        fb.sp = sp
        return len(fb.out) - 1

    def here(self) -> int:
        return len(self.fb.out)

    def patch(self, idx: int, target: int | None = None) -> None:
        if target is None:
            target = self.here()
        ins = self.fb.out[idx]
        # the jump target lives in operand c for tested jumps, a otherwise
        if ins[0] in _C_TARGET:
            ins[3] = target
        else:
            ins[1] = target

    def patch_all(self, idxs, target=None) -> None:
        for i in idxs:
            self.patch(i, target)

    # -------------------------------------------------------------- variables
    def slot(self, v: LocalVar) -> int:
        fb = self.fb
        if v.ctx is fb.ctx:
            return v.slot
        return fb.nparams + fb.ctx.captures[v]

    def declare(self, v: LocalVar) -> int:
        v.slot = self.fb.new_slot()
        return v.slot

    # ------------------------------------------------------------- statements
    def stmt(self, s) -> None:
        c = type(s)
        if c is S.ExprStmt:
            self.discard(s.expr)
        elif c is S.Let:
            self.let(s)
        elif c is S.VarDecl:
            self.expr(s.expr)
            self.emit(O.STORE, self.declare(s.var))
        elif c is S.Assign:
            self.assign(s)
        elif c is S.Return:
            self.return_(s)
        elif c is S.While:
            self.while_(s)
        elif c is S.For:
            self.for_(s)
        elif c is S.Break or c is S.Continue:
            lp = self.fb.loops[-1]
            extra = self.fb.sp - lp.sp
            if extra:
                self.emit(O.POPN, extra)
                self.fb.sp += extra  # unreachable code below keeps the static depth
            j = self.emit(O.JUMP, 0)
            (lp.breaks if c is S.Break else lp.continues).append(j)
        else:
            raise AssertionError(s)

    def let(self, s: S.Let) -> None:
        p = s.pat
        self.expr(s.expr)
        if type(p) is S.PBind and p.variant is None:
            self.emit(O.STORE, self.declare(p.var))
        elif type(p) is S.PWild:
            self.emit(O.POP)
        else:
            tmp = self.fb.new_slot()
            self.emit(O.STORE, tmp)
            self.pattern(p, tmp, None)

    def assign(self, s: S.Assign) -> None:
        if s.tag == "local":
            self.expr(s.expr)
            self.emit(O.STORE, s.var.slot)
            return
        t = s.target
        self.expr(t.base)
        self.expr(t.index)
        self.expr(s.expr)
        self.emit(O.SETL if s.tag == "list" else O.SETM)

    def return_(self, s: S.Return) -> None:
        if s.expr is None:
            self.emit(O.CONST, None)
        else:
            self.expr(s.expr)
        extra = self.fb.sp - 1
        if extra:
            self.emit(O.RETN, extra)
        else:
            self.emit(O.RET)

    def while_(self, s: S.While) -> None:
        fb = self.fb
        top = self.here()
        exits = self.jump_false(s.cond)
        lp = Loop(fb.sp)
        fb.loops.append(lp)
        self.block_stmts(s.body)
        fb.loops.pop()
        self.emit(O.JUMP, top)
        end = self.here()
        self.patch_all(exits, end)
        self.patch_all(lp.breaks, end)
        self.patch_all(lp.continues, top)

    def block_stmts(self, b: S.Block) -> None:
        for st in b.stmts:
            self.stmt(st)
        if b.tail is not None:
            self.discard(b.tail)

    def for_(self, s: S.For) -> None:
        fb = self.fb
        pat = s.pat
        simple = type(pat) is S.PBind and pat.variant is None
        wild = type(pat) is S.PWild
        if s.tag == "range":
            i = fb.new_slot()
            end = fb.new_slot()  # must be i + 1
            assert end == i + 1
            self.expr(s.iter)
            self.emit(O.STORE, i)
            self.expr(s.hi)
            self.emit(O.STORE, end)
            var = self.declare(pat.var) if simple else -1
            top = self.here()
            test = self.emit(O.FORRANGE, i, var, 0)
            lp = Loop(fb.sp)
            fb.loops.append(lp)
            if not simple and not wild:
                self.emit(O.LOAD, i)
                tmp = fb.new_slot()
                self.emit(O.STORE, tmp)
                self.pattern(pat, tmp, None)
            self.block_stmts(s.body)
            fb.loops.pop()
            cont = self.emit(O.INCJ, i, top)
            end_pc = self.here()
            fb.out[test][3] = end_pc
            self.patch_all(lp.breaks, end_pc)
            self.patch_all(lp.continues, cont)
            return
        seq = fb.new_slot()
        idx = fb.new_slot()  # must be seq + 1
        assert idx == seq + 1
        self.expr(s.iter)
        self.emit(O.STORE, seq)
        self.emit(O.CONST, 0)
        self.emit(O.STORE, idx)
        top = self.here()
        op = O.FORLIST if s.tag == "list" else O.FORSTR
        var = self.declare(pat.var) if simple else -1
        test = self.emit(op, seq, var, 0)
        lp = Loop(fb.sp)
        fb.loops.append(lp)
        if not simple:
            if wild:
                self.emit(O.POP)
            else:
                tmp = fb.new_slot()
                self.emit(O.STORE, tmp)
                self.pattern(pat, tmp, None)
        self.block_stmts(s.body)
        fb.loops.pop()
        self.emit(O.JUMP, top)
        end_pc = self.here()
        fb.out[test][3] = end_pc
        self.patch_all(lp.breaks, end_pc)
        self.patch_all(lp.continues, top)

    # -------------------------------------------------------------- patterns
    def pattern(self, p, src: int, fails: list | None) -> None:
        """Emit tests (jumping to ``fails`` on mismatch) and bindings for ``loc[src]``.

        ``fails`` is ``None`` for an irrefutable context (no tests are emitted)."""
        c = type(p)
        if c is S.PWild:
            return
        if c is S.PBind:
            if p.variant is not None:
                if fails is not None:
                    fails.append(self.emit(O.JNV, src, p.variant.uid, 0))
            else:
                self.emit(O.COPY, src, self.declare(p.var))
            return
        if c is S.PLit:
            fails.append(self.emit(O.JNEQ, src, self.lit(p), 0))
            return
        if c is S.PTuple:
            for i, sp in enumerate(p.items):
                self.component(sp, src, O.LOADTUP, i, fails)
            return
        if c is S.PVariant:
            if fails is not None:
                fails.append(self.emit(O.JNV, src, p.variant.uid, 0))
            for i, sp in enumerate(p.args or ()):
                self.component(sp, src, O.LOADFIELD, i, fails)
            return
        if c is S.PStruct:
            for f in p.fields:
                if f.pat is None:
                    self.emit(O.LOADFIELD, src, f.index)
                    self.emit(O.STORE, self.declare(f.var))
                else:
                    self.component(f.pat, src, O.LOADFIELD, f.index, fails)
            return
        if c is S.PList:
            n = len(p.items)
            if fails is not None:
                fails.append(self.emit(O.JLENGE if p.has_rest else O.JLEN, src, n, 0))
            for i, sp in enumerate(p.items):
                self.component(sp, src, O.LOADELEM, i, fails)
            if p.rest_var is not None:
                self.emit(O.LISTREST, src, n)
                self.emit(O.STORE, self.declare(p.rest_var))
            return
        raise AssertionError(p)

    def component(self, sp, src, load_op, i, fails) -> None:
        c = type(sp)
        if c is S.PWild:
            return
        if c is S.PBind and sp.variant is None:
            self.emit(load_op, src, i)
            self.emit(O.STORE, self.declare(sp.var))
            return
        self.emit(load_op, src, i)
        tmp = self.fb.new_slot()
        self.emit(O.STORE, tmp)
        self.pattern(sp, tmp, fails)

    def lit(self, p: S.PLit):
        if p.kind == "char":
            return Char(p.value)
        return p.value

    # ---------------------------------------------------------- expressions
    def discard(self, e) -> None:
        """Compile ``e`` for its effects only."""
        c = type(e)
        if c is S.If:
            self.if_(e, False)
        elif c is S.Match:
            self.match(e, False)
        else:
            self.expr(e)
            self.emit(O.POP)

    def expr(self, e) -> None:
        self._EXPR[type(e)](self, e)

    def e_const(self, e) -> None:
        self.emit(O.CONST, e.value)

    def e_char(self, e) -> None:
        self.emit(O.CONST, Char(e.value))

    def e_self(self, e) -> None:
        self.emit(O.LOAD, self.slot(e.var))

    def e_path(self, e: S.PathExpr) -> None:
        kind, x = e.res
        if kind == "local":
            self.emit(O.LOAD, self.slot(x))
        else:  # zero-payload variant
            self.emit(O.CONST, (x.uid,))

    def e_unary(self, e: S.Unary) -> None:
        self.expr(e.operand)
        op = e.op
        if op == "-":
            self.emit(O.NEG if e.tag == "int" else O.FNEG)
        elif op == "!":
            self.emit(O.NOT)
        else:
            self.emit(O.BNOT)

    def e_binary(self, e: S.Binary) -> None:
        op = e.op
        if op == "&&" or op == "||":
            self.expr(e.left)
            j = self.emit(O.JFK if op == "&&" else O.JTK, 0)
            self.expr(e.right)
            self.patch(j)
            return
        self.expr(e.left)
        self.expr(e.right)
        if op in _BIN_INT:
            self.emit(_BIN_INT[op] if e.tag == "int" else _BIN_FLOAT[op])
        elif op == "++":
            self.emit(O.CATS if e.tag == "str" else O.CATL)
        elif op in _BITS:
            self.emit(_BITS[op])
        elif op in _CMP:
            self.emit(_CMP[op])
        elif op == "==":
            self.emit(O.DEQ if e.tag == "deep" else O.EQ)
        else:
            self.emit(O.DNE if e.tag == "deep" else O.NE)

    def jump_false(self, e) -> list[int]:
        """Compile condition ``e``; return jumps taken when it is false."""
        c = type(e)
        if c is S.Binary:
            op = e.op
            if op == "&&":
                a = self.jump_false(e.left)
                return a + self.jump_false(e.right)
            if op in _CMP_JUMP:
                self.expr(e.left)
                self.expr(e.right)
                return [self.emit(_CMP_JUMP[op], 0, 0, 0)]
            if op == "==" and e.tag == "eq":
                self.expr(e.left)
                self.expr(e.right)
                return [self.emit(O.JEQ, 0, 0, 0)]
            if op == "!=" and e.tag == "eq":
                self.expr(e.left)
                self.expr(e.right)
                return [self.emit(O.JNE, 0, 0, 0)]
        self.expr(e)
        return [self.emit(O.JIF, 0)]

    def e_call(self, e: S.Call) -> None:
        kind = e.kind
        args = e.args
        if kind == "func":
            for a in args:
                self.expr(a)
            self.emit(O.CALL, e.target.code, len(args))
        elif kind == "builtin":
            for a in args:
                self.expr(a)
            b = e.target
            self.emit(O.CALLH if b.name in HIGHER_ORDER else O.CALLB, b.id, len(args))
        elif kind == "variant":
            for a in args:
                self.expr(a)
            self.emit(O.MKENUM, e.target.uid, len(args))
        elif kind == "value":
            self.expr(e.callee)
            for a in args:
                self.expr(a)
            self.emit(O.CALLV, 0, len(args))
        else:  # Tr::m(recv, ...)
            trait, ms, target = e.target
            self.method(args[0], args[1:], trait, ms.index, target)

    def e_method(self, e: S.MethodCall) -> None:
        self.method(e.recv, e.args, e.trait, e.midx, e.target)

    def method(self, recv, args, trait, midx, target) -> None:
        self.expr(recv)
        for a in args:
            self.expr(a)
        if target is not None:
            self.emit(O.CALL, target.code, len(args) + 1)
        else:
            self.emit(O.CALLM, self.table_for(trait.uid, midx), len(args))

    def e_field(self, e: S.FieldAccess) -> None:
        self.expr(e.obj)
        self.emit(O.FIELD, e.index)

    def e_index(self, e: S.Index) -> None:
        self.expr(e.base)
        self.expr(e.index)
        self.emit({"list": O.IDXL, "str": O.IDXS, "map": O.IDXM}[e.tag])

    def e_list(self, e: S.ListLit) -> None:
        for x in e.items:
            self.expr(x)
        self.emit(O.MKLIST, 0, len(e.items))

    def e_map(self, e: S.MapLit) -> None:
        for k, v in e.entries:
            self.expr(k)
            self.expr(v)
        self.emit(O.MKMAP, len(e.entries))

    def e_tuple(self, e: S.TupleLit) -> None:
        for x in e.items:
            self.expr(x)
        self.emit(O.MKTUP, 0, len(e.items))

    def e_structlit(self, e: S.StructLit) -> None:
        for f in e.fields:
            self.expr(f.expr)
        n = len(e.fields)
        if e.perm is None:
            self.emit(O.MKSTRUCT, e.decl.uid, n)
        else:
            inv = [0] * n
            for written, decl_idx in enumerate(e.perm):
                inv[decl_idx] = written
            self.emit(O.MKSTRUCT, e.decl.uid, n, tuple(inv))

    def e_lambda(self, e: S.Lambda) -> None:
        ctx = e.ctx
        code = Code("<lambda>")
        outer = self.fb
        caps = sorted(ctx.captures.items(), key=lambda kv: kv[1])
        for v, _ in caps:
            self.emit(O.LOAD, self.slot(v))
        self.emit(O.MKCLOS, code, len(caps))
        nparams = len(ctx.param_vars)
        self.fb = FnBuilder(code, ctx, nparams)
        for i, v in enumerate(ctx.param_vars):
            v.slot = i
        self.body(e.body)
        self.finish(code, nparams, ctx)
        self.fb = outer

    def e_block(self, b: S.Block) -> None:
        for st in b.stmts:
            self.stmt(st)
        if b.tail is not None:
            self.expr(b.tail)
        else:
            self.emit(O.CONST, None)

    def e_if(self, e: S.If) -> None:
        self.if_(e, True)

    def if_(self, e: S.If, want: bool) -> None:
        fb = self.fb
        elses = self.jump_false(e.cond)
        base = fb.sp
        self.branch(e.then, want)
        if e.els is None and not want:
            self.patch_all(elses)
            return
        j = self.emit(O.JUMP, 0)
        self.patch_all(elses)
        fb.sp = base
        if e.els is None:
            self.emit(O.CONST, None)
        else:
            self.branch(e.els, want)
        self.patch(j)

    def branch(self, b, want: bool) -> None:
        if want:
            self.expr(b)
        else:
            self.discard_block(b)

    def discard_block(self, b) -> None:
        if type(b) is S.Block:
            for st in b.stmts:
                self.stmt(st)
            if b.tail is not None:
                self.discard(b.tail)
        else:
            self.discard(b)

    def e_match(self, e: S.Match) -> None:
        self.match(e, True)

    def match(self, e: S.Match, want: bool) -> None:
        fb = self.fb
        self.expr(e.scrut)
        tmp = fb.new_slot()
        self.emit(O.STORE, tmp)
        base = fb.sp
        ends = []
        for arm in e.arms:
            fails: list[int] = []
            self.pattern(arm.pat, tmp, fails)
            if arm.guard is not None:
                fails += self.jump_false(arm.guard)
            self.branch(arm.body, want)
            ends.append(self.emit(O.JUMP, 0))
            self.patch_all(fails)
            fb.sp = base
        self.emit(O.NOMATCH)
        if want:
            fb.sp = base + 1
        self.patch_all(ends)

    _EXPR: dict = {}


# instructions whose jump target is operand c (a, b hold tested operands)
_C_TARGET = frozenset(
    (O.JNV, O.JLEN, O.JLENGE, O.JNEQ, O.JLT, O.JLE, O.JGT, O.JGE, O.JEQ, O.JNE, O.FORLIST, O.FORSTR, O.FORRANGE)
)

Compiler._EXPR = {
    S.IntLit: Compiler.e_const,
    S.FloatLit: Compiler.e_const,
    S.StrLit: Compiler.e_const,
    S.BoolLit: Compiler.e_const,
    S.CharLit: Compiler.e_char,
    S.SelfExpr: Compiler.e_self,
    S.PathExpr: Compiler.e_path,
    S.StructLit: Compiler.e_structlit,
    S.Unary: Compiler.e_unary,
    S.Binary: Compiler.e_binary,
    S.Call: Compiler.e_call,
    S.MethodCall: Compiler.e_method,
    S.Index: Compiler.e_index,
    S.FieldAccess: Compiler.e_field,
    S.ListLit: Compiler.e_list,
    S.MapLit: Compiler.e_map,
    S.TupleLit: Compiler.e_tuple,
    S.Lambda: Compiler.e_lambda,
    S.If: Compiler.e_if,
    S.Match: Compiler.e_match,
    S.Block: Compiler.e_block,
}
