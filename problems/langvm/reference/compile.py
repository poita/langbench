"""The bytecode compiler: a checked AST becomes function code arrays."""

import ops
from vast import (
    EInt, EFloat, EStr, EChar, EBool, ESelf, EPath, EUnary, EBinary, ECall,
    EMethod, EIndex, EField, EStructLit, EList, EMap, ETuple, ELambda, EIf,
    EMatch, EBlock,
    SLet, SVar, SAssign, SExpr, SWhile, SForSeq, SForRange, SBreak, SContinue,
    SReturn,
    PWild, PInt, PStr, PChar, PBool, PBind, PVariant, PStruct, PTuple, PList,
    IFn, ITrait, IImpl,
)
from values import VChar

CMP_OP = {'<': ops.LT, '<=': ops.LE, '>': ops.GT, '>=': ops.GE}


class CompiledProgram:
    """The compiled program handed to the VM."""

    def __init__(self):
        self.funcs = []          # FuncInfo objects, index = position
        self.method_table = {}   # (trait index, ctor) -> [func index]
        self.main = -1


def compile_program(prog, checker):
    out = CompiledProgram()
    out.funcs = checker.funcs
    for m in prog.modules:
        for it in m.items:
            k = type(it)
            if k is IFn:
                FnCompiler(it.info).run_body(it.body, it.info.ret)
            elif k is ITrait:
                for meth in it.methods:
                    if meth.body is not None:
                        FnCompiler(meth.info).run_body(meth.body,
                                                       meth.info.ret)
            elif k is IImpl:
                for meth in it.methods:
                    FnCompiler(meth.info).run_body(meth.body, meth.info.ret)
    for impl in prog.impl_list:
        trait = impl.trait
        slots = []
        for i, tm in enumerate(trait.methods):
            meth = impl.methods[i]
            if meth is not None:
                slots.append(meth.info.index)
            else:
                slots.append(tm.info.index)
        out.method_table[(trait.index, impl.ctor)] = slots
    out.main = prog.main_fn.info.index
    return out


class Loop:
    __slots__ = ('breaks', 'continues')

    def __init__(self):
        self.breaks = []
        self.continues = []


class FnCompiler:
    def __init__(self, info):
        self.info = info
        self.code = []
        self.loops = []

    def temp(self):
        s = self.info.nslots
        self.info.nslots += 1
        return s

    def emit(self, op, a=0, b=0, c=0):
        self.code.append((op, a, b, c))
        return len(self.code) - 1

    def patch(self, idx, target=None):
        if target is None:
            target = len(self.code)
        op, _a, b, c = self.code[idx]
        self.code[idx] = (op, target, b, c)

    def here(self):
        return len(self.code)

    def run_body(self, block, ret):
        self.stmts(block.stmts)
        if block.tail is not None:
            self.expr(block.tail)
            self.emit(ops.RET)
        else:
            self.emit(ops.RET_UNIT)
        self.info.code = self.code

    # -- statements ------------------------------------------------------

    def stmts(self, lst):
        for s in lst:
            self.stmt(s)

    def stmt(self, s):
        k = type(s)
        if k is SExpr:
            self.expr(s.expr)
            self.emit(ops.POP)
        elif k is SLet:
            self.expr(s.expr)
            self.bind_stack(s.pat)
        elif k is SVar:
            self.expr(s.expr)
            self.emit(ops.STORE_LOCAL, s.bind.slot)
        elif k is SAssign:
            t = s.target
            if type(t) is EPath:
                self.expr(s.expr)
                self.emit(ops.STORE_LOCAL, s.bind.slot)
            else:
                self.expr(t.obj)
                self.expr(t.index)
                self.expr(s.expr)
                self.emit(ops.INDEX_SET)
        elif k is SReturn:
            if s.expr is None:
                self.emit(ops.RET_UNIT)
            else:
                self.expr(s.expr)
                self.emit(ops.RET)
        elif k is SWhile:
            start = self.here()
            loop = Loop()
            self.loops.append(loop)
            self.expr(s.cond)
            exit_jump = self.emit(ops.JUMP_IF_FALSE, 0)
            self.stmt_block(s.body)
            self.emit(ops.JUMP, start)
            self.patch(exit_jump)
            for j in loop.breaks:
                self.patch(j)
            for j in loop.continues:
                self.patch(j, start)
            self.loops.pop()
        elif k is SForSeq:
            self.for_seq(s)
        elif k is SForRange:
            self.for_range(s)
        elif k is SBreak:
            self.loops[-1].breaks.append(self.emit(ops.JUMP, 0))
        elif k is SContinue:
            self.loops[-1].continues.append(self.emit(ops.JUMP, 0))
        else:
            raise AssertionError('bad statement')

    def stmt_block(self, b):
        self.stmts(b.stmts)
        if b.tail is not None:
            self.expr(b.tail)
            self.emit(ops.POP)

    def for_seq(self, s):
        seq = self.temp()
        idx = self.temp()
        self.expr(s.seq)
        self.emit(ops.STORE_LOCAL, seq)
        self.emit(ops.PUSH_CONST, 0)
        self.emit(ops.STORE_LOCAL, idx)
        start = self.here()
        self.emit(ops.LOAD_LOCAL, idx)
        self.emit(ops.LOAD_LOCAL, seq)
        self.emit(ops.SEQ_LEN)
        self.emit(ops.LT)
        exit_jump = self.emit(ops.JUMP_IF_FALSE, 0)
        self.emit(ops.LOAD_LOCAL, seq)
        self.emit(ops.LOAD_LOCAL, idx)
        self.emit(ops.INDEX_GET)
        self.bind_stack(s.pat)
        loop = Loop()
        self.loops.append(loop)
        self.stmt_block(s.body)
        self.loops.pop()
        cont = self.here()
        self.emit(ops.INC_LOCAL, idx)
        self.emit(ops.JUMP, start)
        self.patch(exit_jump)
        for j in loop.breaks:
            self.patch(j)
        for j in loop.continues:
            self.patch(j, cont)

    def for_range(self, s):
        var = self.temp()
        lim = self.temp()
        self.expr(s.lo)
        self.emit(ops.STORE_LOCAL, var)
        self.expr(s.hi)
        self.emit(ops.STORE_LOCAL, lim)
        start = self.here()
        self.emit(ops.LOAD_LOCAL, var)
        self.emit(ops.LOAD_LOCAL, lim)
        self.emit(ops.LT)
        exit_jump = self.emit(ops.JUMP_IF_FALSE, 0)
        self.emit(ops.LOAD_LOCAL, var)
        self.bind_stack(s.pat)
        loop = Loop()
        self.loops.append(loop)
        self.stmt_block(s.body)
        self.loops.pop()
        cont = self.here()
        self.emit(ops.INC_LOCAL, var)
        self.emit(ops.JUMP, start)
        self.patch(exit_jump)
        for j in loop.breaks:
            self.patch(j)
        for j in loop.continues:
            self.patch(j, cont)

    # -- irrefutable binding of a value on the stack ----------------------

    def bind_stack(self, pat):
        k = type(pat)
        if k is PWild:
            self.emit(ops.POP)
        elif k is PBind:
            self.emit(ops.STORE_LOCAL, pat.bind.slot)
        elif k is PVariant and pat.bind is not None:
            self.emit(ops.STORE_LOCAL, pat.bind.slot)
        elif k is PVariant:
            subs = pat.subs or ()
            for i, sub in enumerate(subs):
                self.emit(ops.DUP)
                self.emit(ops.GET_PAYLOAD, i)
                self.bind_stack(sub)
            self.emit(ops.POP)
        elif k is PStruct:
            for idx, sub in pat.order:
                self.emit(ops.DUP)
                self.emit(ops.GET_FIELD, idx)
                self.bind_stack(sub)
            self.emit(ops.POP)
        elif k is PTuple:
            for i, sub in enumerate(pat.parts):
                self.emit(ops.DUP)
                self.emit(ops.GET_TUPLE, i)
                self.bind_stack(sub)
            self.emit(ops.POP)
        elif k is PList:
            if pat.restbind is not None:
                self.emit(ops.LIST_REST, len(pat.elems))
                self.emit(ops.STORE_LOCAL, pat.restbind.slot)
            else:
                self.emit(ops.POP)
        else:
            raise AssertionError('refutable pattern in a binding position')

    # -- refutable matching from a root slot ------------------------------

    def load_path(self, root, steps):
        self.emit(ops.LOAD_LOCAL, root)
        for kind, i in steps:
            if kind == 'payload':
                self.emit(ops.GET_PAYLOAD, i)
            elif kind == 'field':
                self.emit(ops.GET_FIELD, i)
            elif kind == 'tuple':
                self.emit(ops.GET_TUPLE, i)
            elif kind == 'elem':
                self.emit(ops.PUSH_CONST, i)
                self.emit(ops.INDEX_GET)
            elif kind == 'rest':
                self.emit(ops.LIST_REST, i)

    def pat_test(self, pat, root, steps, fails):
        k = type(pat)
        if k is PWild:
            return
        if k is PBind or (k is PVariant and pat.bind is not None):
            self.load_path(root, steps)
            self.emit(ops.STORE_LOCAL, pat.bind.slot)
            return
        if k is PInt or k is PStr or k is PBool or k is PChar:
            self.load_path(root, steps)
            if k is PBool:
                self.emit(ops.PUSH_TRUE if pat.val else ops.PUSH_FALSE)
            elif k is PChar:
                self.emit(ops.PUSH_CONST, VChar(pat.val))
            else:
                self.emit(ops.PUSH_CONST, pat.val)
            self.emit(ops.EQ)
            fails.append(self.emit(ops.JUMP_IF_FALSE, 0))
            return
        if k is PVariant:
            self.load_path(root, steps)
            self.emit(ops.IS_VARIANT, pat.vd.index)
            fails.append(self.emit(ops.JUMP_IF_FALSE, 0))
            for i, sub in enumerate(pat.subs or ()):
                self.pat_test(sub, root, steps + [('payload', i)], fails)
            return
        if k is PStruct:
            for idx, sub in pat.order:
                self.pat_test(sub, root, steps + [('field', idx)], fails)
            return
        if k is PTuple:
            for i, sub in enumerate(pat.parts):
                self.pat_test(sub, root, steps + [('tuple', i)], fails)
            return
        if k is PList:
            n = len(pat.elems)
            self.load_path(root, steps)
            self.emit(ops.SEQ_LEN)
            self.emit(ops.PUSH_CONST, n)
            self.emit(ops.GE if pat.rest else ops.EQ)
            fails.append(self.emit(ops.JUMP_IF_FALSE, 0))
            for i, sub in enumerate(pat.elems):
                self.pat_test(sub, root, steps + [('elem', i)], fails)
            if pat.restbind is not None:
                self.load_path(root, steps + [('rest', n)])
                self.emit(ops.STORE_LOCAL, pat.restbind.slot)
            return
        raise AssertionError('bad pattern')

    # -- expressions -----------------------------------------------------

    def expr(self, e):
        k = type(e)
        if k is EInt or k is EFloat or k is EStr:
            self.emit(ops.PUSH_CONST, e.val)
        elif k is EChar:
            self.emit(ops.PUSH_CONST, VChar(e.val))
        elif k is EBool:
            self.emit(ops.PUSH_TRUE if e.val else ops.PUSH_FALSE)
        elif k is EPath or k is ESelf:
            res = e.res
            if res[0] == 'local':
                self.emit(ops.LOAD_LOCAL, res[1])
            elif res[0] == 'upval':
                self.emit(ops.LOAD_UPVAL, res[1])
            elif res[0] == 'variant':
                vd = res[1]
                self.emit(ops.MAKE_ENUM, vd.enum, vd.index, 0)
            else:
                raise AssertionError('bad value reference')
        elif k is EUnary:
            self.expr(e.operand)
            if e.kind == 'int':
                self.emit(ops.NEG_I)
            elif e.kind == 'float':
                self.emit(ops.NEG_F)
            elif e.kind == 'not':
                self.emit(ops.NOT_B)
            else:
                self.emit(ops.BNOT)
        elif k is EBinary:
            self.binary(e)
        elif k is ECall:
            self.call(e)
        elif k is EMethod:
            tr, mi = e.res[1], e.res[2]
            self.expr(e.recv)
            for a in e.args:
                self.expr(a)
            self.emit(ops.CALL_METHOD, tr.index, mi, len(e.args))
        elif k is EIndex:
            self.expr(e.obj)
            self.expr(e.index)
            self.emit(ops.INDEX_GET)
        elif k is EField:
            self.expr(e.obj)
            self.emit(ops.GET_FIELD, e.idx)
        elif k is EStructLit:
            self.struct_lit(e)
        elif k is EList:
            for x in e.elems:
                self.expr(x)
            self.emit(ops.MAKE_LIST, len(e.elems))
        elif k is EMap:
            for key, val in e.entries:
                self.expr(key)
                self.expr(val)
            self.emit(ops.MAKE_MAP, len(e.entries))
        elif k is ETuple:
            for p in e.parts:
                self.expr(p)
            self.emit(ops.MAKE_TUPLE, len(e.parts))
        elif k is ELambda:
            self.lambda_expr(e)
        elif k is EIf:
            self.if_expr(e)
        elif k is EMatch:
            self.match_expr(e)
        elif k is EBlock:
            self.block_expr(e)
        else:
            raise AssertionError('bad expression %r' % (e,))

    def binary(self, e):
        op = e.op
        if e.kind == 'logic':
            self.expr(e.left)
            if op == '&&':
                j = self.emit(ops.JUMP_IF_FALSE, 0)
                self.expr(e.right)
                end = self.emit(ops.JUMP, 0)
                self.patch(j)
                self.emit(ops.PUSH_FALSE)
                self.patch(end)
            else:
                j = self.emit(ops.JUMP_IF_TRUE, 0)
                self.expr(e.right)
                end = self.emit(ops.JUMP, 0)
                self.patch(j)
                self.emit(ops.PUSH_TRUE)
                self.patch(end)
            return
        self.expr(e.left)
        self.expr(e.right)
        kind = e.kind
        if kind == 'int':
            self.emit({'+': ops.ADD_I, '-': ops.SUB_I, '*': ops.MUL_I,
                       '/': ops.DIV_I, '%': ops.MOD_I}[op])
        elif kind == 'float':
            self.emit({'+': ops.ADD_F, '-': ops.SUB_F, '*': ops.MUL_F,
                       '/': ops.DIV_F}[op])
        elif kind == 'bits':
            self.emit({'&': ops.BAND, '|': ops.BOR, '^': ops.BXOR,
                       '<<': ops.SHL, '>>': ops.SHR}[op])
        elif kind == 'str':
            self.emit(ops.CONCAT_STR)
        elif kind == 'list':
            self.emit(ops.CONCAT_LIST)
        elif kind == 'cmp':
            self.emit(CMP_OP[op])
        elif kind == 'eq':
            self.emit(ops.EQ if op == '==' else ops.NE)
        else:
            raise AssertionError('bad binary kind')

    def call(self, e):
        res = e.res
        tag = res[0]
        if tag == 'fn':
            for a in e.args:
                self.expr(a)
            self.emit(ops.CALL, res[1].info.index, len(e.args))
        elif tag == 'builtin':
            for a in e.args:
                self.expr(a)
            self.emit(ops.CALL_BUILTIN, res[1], len(e.args))
        elif tag == 'variant':
            vd = res[1]
            for a in e.args:
                self.expr(a)
            self.emit(ops.MAKE_ENUM, vd.enum, vd.index, len(e.args))
        elif tag == 'method':
            tr, mi = res[1], res[2]
            for a in e.args:
                self.expr(a)
            self.emit(ops.CALL_METHOD, tr.index, mi, len(e.args) - 1)
        elif tag == 'indirect':
            self.expr(e.callee)
            for a in e.args:
                self.expr(a)
            self.emit(ops.CALL_VALUE, len(e.args))
        else:
            raise AssertionError('bad call')

    def struct_lit(self, e):
        n = len(e.fields)
        if e.perm == list(range(n)):
            for _name, _l, _c, val in e.fields:
                self.expr(val)
            self.emit(ops.MAKE_STRUCT, e.decl, n)
            return
        slots = []
        for _name, _l, _c, val in e.fields:
            s = self.temp()
            slots.append(s)
            self.expr(val)
            self.emit(ops.STORE_LOCAL, s)
        for idx in e.perm:
            self.emit(ops.LOAD_LOCAL, slots[idx])
        self.emit(ops.MAKE_STRUCT, e.decl, n)

    def lambda_expr(self, e):
        info = e.info
        for b in info.captures:
            if b.func is self.info:
                self.emit(ops.LOAD_LOCAL, b.slot)
            else:
                self.emit(ops.LOAD_UPVAL, self.info.upidx[b])
        self.emit(ops.MAKE_CLOSURE, info.index, len(info.captures))
        sub = FnCompiler(info)
        if type(e.body) is EBlock:
            sub.run_body(e.body, info.ret)
        else:
            sub.expr(e.body)
            sub.emit(ops.RET)
            info.code = sub.code

    def if_expr(self, e):
        self.expr(e.cond)
        j = self.emit(ops.JUMP_IF_FALSE, 0)
        self.expr(e.then)
        if e.els is None:
            end = self.emit(ops.JUMP, 0)
            self.patch(j)
            self.emit(ops.PUSH_UNIT)
            self.patch(end)
            return
        end = self.emit(ops.JUMP, 0)
        self.patch(j)
        self.expr(e.els)
        self.patch(end)

    def block_expr(self, e):
        self.stmts(e.stmts)
        if e.tail is not None:
            self.expr(e.tail)
        else:
            # Either the block's type is Unit, or it diverges and this is dead
            # code that keeps the stack shape uniform.
            self.emit(ops.PUSH_UNIT)

    def match_expr(self, e):
        root = self.temp()
        self.expr(e.scrut)
        self.emit(ops.STORE_LOCAL, root)
        ends = []
        for arm in e.arms:
            fails = []
            self.pat_test(arm.pat, root, [], fails)
            if arm.guard is not None:
                self.expr(arm.guard)
                fails.append(self.emit(ops.JUMP_IF_FALSE, 0))
            self.expr(arm.body)
            ends.append(self.emit(ops.JUMP, 0))
            for j in fails:
                self.patch(j)
        self.emit(ops.NO_MATCH)
        for j in ends:
            self.patch(j)
