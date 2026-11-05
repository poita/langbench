"""The stack virtual machine.

Frames live in a flat list, so Vellum recursion never recurses in the host;
the only host recursion is one level per higher-order built-in that calls back
into the machine (`listMap`, `sortBy`, ...).
"""

import ops
from verrors import Panic
from values import (VChar, UNIT, StructVal, EnumVal, Closure, vals_equal,
                    value_ctor)
from blib import BUILTIN_FNS, fdiv, MASK64

MAX_FRAMES = 20000
INT_MIN = -(1 << 63)
INT_MAX = (1 << 63) - 1


def wrap(x):
    x &= MASK64
    return x - (1 << 64) if x >= (1 << 63) else x


class VM:
    def __init__(self, program):
        self.funcs = program.funcs
        self.method_table = program.method_table
        self.main = program.main
        self.out = []
        self.stack = []
        self.frames = []

    def run(self):
        f = self.funcs[self.main]
        self.stack = [None] * f.nslots
        self.frames = [[f, 0, 0, None]]
        self.exec_loop(0)

    def invoke(self, clo, args):
        """Call a closure from inside a built-in."""
        stack = self.stack
        f = self.funcs[clo.func]
        base = len(stack)
        stack.extend(args)
        if f.nslots > len(args):
            stack.extend([None] * (f.nslots - len(args)))
        if len(self.frames) + 1 > MAX_FRAMES:
            raise Panic('call stack overflow')
        self.frames.append([f, 0, base, clo.upvals])
        self.exec_loop(len(self.frames) - 1)
        return stack.pop()

    def exec_loop(self, stop):
        stack = self.stack
        frames = self.frames
        funcs = self.funcs
        fr = frames[-1]
        func = fr[0]
        code = func.code
        pc = 0
        base = fr[2]
        upvals = fr[3]
        while True:
            op, a, b, c = code[pc]
            pc += 1
            if op == ops.LOAD_LOCAL:
                stack.append(stack[base + a])
            elif op == ops.PUSH_CONST:
                stack.append(a)
            elif op == ops.JUMP_IF_FALSE:
                if not stack.pop():
                    pc = a
            elif op == ops.ADD_I:
                y = stack.pop()
                x = stack.pop()
                r = x + y
                stack.append(r if INT_MIN <= r <= INT_MAX else wrap(r))
            elif op == ops.LT:
                y = stack.pop()
                x = stack.pop()
                stack.append(x < y)
            elif op == ops.CALL:
                nf = funcs[a]
                nbase = len(stack) - b
                if nf.nslots > b:
                    stack.extend([None] * (nf.nslots - b))
                if len(frames) + 1 > MAX_FRAMES:
                    raise Panic('call stack overflow')
                fr[1] = pc
                fr = [nf, 0, nbase, None]
                frames.append(fr)
                func = nf
                code = nf.code
                pc = 0
                base = nbase
                upvals = None
            elif op == ops.RET:
                v = stack.pop()
                del stack[base:]
                frames.pop()
                stack.append(v)
                if len(frames) == stop:
                    return
                fr = frames[-1]
                func = fr[0]
                code = func.code
                pc = fr[1]
                base = fr[2]
                upvals = fr[3]
            elif op == ops.STORE_LOCAL:
                stack[base + a] = stack.pop()
            elif op == ops.JUMP:
                pc = a
            elif op == ops.CALL_BUILTIN:
                n = len(stack) - b
                args = stack[n:]
                del stack[n:]
                stack.append(BUILTIN_FNS[a](self, args))
            elif op == ops.EQ:
                y = stack.pop()
                x = stack.pop()
                t = type(x)
                if t is int or t is str or t is VChar or t is float or t is bool:
                    stack.append(x == y)
                else:
                    stack.append(vals_equal(x, y))
            elif op == ops.INDEX_GET:
                i = stack.pop()
                cont = stack.pop()
                t = type(cont)
                if t is list:
                    if i < 0 or i >= len(cont):
                        raise Panic('index out of bounds')
                    stack.append(cont[i])
                elif t is dict:
                    if i not in cont:
                        raise Panic('missing key')
                    stack.append(cont[i])
                else:
                    if i < 0 or i >= len(cont):
                        raise Panic('index out of bounds')
                    stack.append(VChar(cont[i]))
            elif op == ops.SUB_I:
                y = stack.pop()
                x = stack.pop()
                r = x - y
                stack.append(r if INT_MIN <= r <= INT_MAX else wrap(r))
            elif op == ops.INC_LOCAL:
                i = base + a
                r = stack[i] + 1
                stack[i] = r if r <= INT_MAX else INT_MIN
            elif op == ops.MUL_I:
                y = stack.pop()
                x = stack.pop()
                r = x * y
                stack.append(r if INT_MIN <= r <= INT_MAX else wrap(r))
            elif op == ops.GET_FIELD:
                stack.append(stack.pop().fields[a])
            elif op == ops.SEQ_LEN:
                stack.append(len(stack.pop()))
            elif op == ops.IS_VARIANT:
                stack.append(stack.pop().variant == a)
            elif op == ops.GET_PAYLOAD:
                stack.append(stack.pop().payload[a])
            elif op == ops.POP:
                stack.pop()
            elif op == ops.DUP:
                stack.append(stack[-1])
            elif op == ops.LE:
                y = stack.pop()
                x = stack.pop()
                stack.append(x <= y)
            elif op == ops.GT:
                y = stack.pop()
                x = stack.pop()
                stack.append(x > y)
            elif op == ops.GE:
                y = stack.pop()
                x = stack.pop()
                stack.append(x >= y)
            elif op == ops.NE:
                y = stack.pop()
                x = stack.pop()
                t = type(x)
                if t is int or t is str or t is VChar or t is float or t is bool:
                    stack.append(x != y)
                else:
                    stack.append(not vals_equal(x, y))
            elif op == ops.CALL_METHOD:
                nbase = len(stack) - c - 1
                recv = stack[nbase]
                slots = self.method_table[(a, value_ctor(recv))]
                nf = funcs[slots[b]]
                if nf.nslots > c + 1:
                    stack.extend([None] * (nf.nslots - c - 1))
                if len(frames) + 1 > MAX_FRAMES:
                    raise Panic('call stack overflow')
                fr[1] = pc
                fr = [nf, 0, nbase, None]
                frames.append(fr)
                func = nf
                code = nf.code
                pc = 0
                base = nbase
                upvals = None
            elif op == ops.RET_UNIT:
                del stack[base:]
                frames.pop()
                stack.append(UNIT)
                if len(frames) == stop:
                    return
                fr = frames[-1]
                func = fr[0]
                code = func.code
                pc = fr[1]
                base = fr[2]
                upvals = fr[3]
            elif op == ops.CALL_VALUE:
                nbase = len(stack) - a - 1
                clo = stack[nbase]
                del stack[nbase]
                nf = funcs[clo.func]
                if nf.nslots > a:
                    stack.extend([None] * (nf.nslots - a))
                if len(frames) + 1 > MAX_FRAMES:
                    raise Panic('call stack overflow')
                fr[1] = pc
                fr = [nf, 0, nbase, clo.upvals]
                frames.append(fr)
                func = nf
                code = nf.code
                pc = 0
                base = nbase
                upvals = clo.upvals
            elif op == ops.LOAD_UPVAL:
                stack.append(upvals[a])
            elif op == ops.MAKE_CLOSURE:
                if b:
                    n = len(stack) - b
                    ups = stack[n:]
                    del stack[n:]
                else:
                    ups = []
                stack.append(Closure(a, ups))
            elif op == ops.PUSH_TRUE:
                stack.append(True)
            elif op == ops.PUSH_FALSE:
                stack.append(False)
            elif op == ops.PUSH_UNIT:
                stack.append(UNIT)
            elif op == ops.JUMP_IF_TRUE:
                if stack.pop():
                    pc = a
            elif op == ops.MAKE_ENUM:
                if c:
                    n = len(stack) - c
                    pay = tuple(stack[n:])
                    del stack[n:]
                else:
                    pay = ()
                stack.append(EnumVal(a, b, pay))
            elif op == ops.MAKE_STRUCT:
                n = len(stack) - b
                fields = stack[n:]
                del stack[n:]
                stack.append(StructVal(a, fields))
            elif op == ops.MAKE_LIST:
                if a:
                    n = len(stack) - a
                    xs = stack[n:]
                    del stack[n:]
                else:
                    xs = []
                stack.append(xs)
            elif op == ops.MAKE_MAP:
                n = len(stack) - 2 * a
                items = stack[n:]
                del stack[n:]
                m = {}
                for j in range(0, len(items), 2):
                    m[items[j]] = items[j + 1]
                stack.append(m)
            elif op == ops.MAKE_TUPLE:
                n = len(stack) - a
                t = tuple(stack[n:])
                del stack[n:]
                stack.append(t)
            elif op == ops.GET_TUPLE:
                stack.append(stack.pop()[a])
            elif op == ops.INDEX_SET:
                v = stack.pop()
                i = stack.pop()
                cont = stack.pop()
                if type(cont) is list:
                    if i < 0 or i >= len(cont):
                        raise Panic('index out of bounds')
                    cont[i] = v
                else:
                    cont[i] = v
            elif op == ops.DIV_I:
                y = stack.pop()
                x = stack.pop()
                if y == 0:
                    raise Panic('divide by zero')
                q = abs(x) // abs(y)
                if (x < 0) != (y < 0):
                    q = -q
                stack.append(q if q <= INT_MAX else INT_MIN)
            elif op == ops.MOD_I:
                y = stack.pop()
                x = stack.pop()
                if y == 0:
                    raise Panic('modulo by zero')
                r = abs(x) % abs(y)
                stack.append(-r if x < 0 else r)
            elif op == ops.NEG_I:
                x = stack.pop()
                stack.append(-x if x != INT_MIN else INT_MIN)
            elif op == ops.ADD_F:
                y = stack.pop()
                stack.append(stack.pop() + y)
            elif op == ops.SUB_F:
                y = stack.pop()
                stack.append(stack.pop() - y)
            elif op == ops.MUL_F:
                y = stack.pop()
                stack.append(stack.pop() * y)
            elif op == ops.DIV_F:
                y = stack.pop()
                stack.append(fdiv(stack.pop(), y))
            elif op == ops.NEG_F:
                stack.append(-stack.pop())
            elif op == ops.NOT_B:
                stack.append(not stack.pop())
            elif op == ops.CONCAT_STR:
                y = stack.pop()
                stack.append(stack.pop() + y)
            elif op == ops.CONCAT_LIST:
                y = stack.pop()
                stack.append(stack.pop() + y)
            elif op == ops.BAND:
                y = stack.pop()
                stack.append(stack.pop() & y)
            elif op == ops.BOR:
                y = stack.pop()
                stack.append(stack.pop() | y)
            elif op == ops.BXOR:
                y = stack.pop()
                stack.append(stack.pop() ^ y)
            elif op == ops.SHL:
                y = stack.pop()
                x = stack.pop()
                if y < 0 or y > 63:
                    raise Panic('shift amount out of range')
                stack.append(wrap(x << y))
            elif op == ops.SHR:
                y = stack.pop()
                x = stack.pop()
                if y < 0 or y > 63:
                    raise Panic('shift amount out of range')
                stack.append(x >> y)
            elif op == ops.BNOT:
                stack.append(~stack.pop())
            elif op == ops.LIST_REST:
                stack.append(stack.pop()[a:])
            elif op == ops.NO_MATCH:
                raise Panic('no match')
            elif op == ops.PANIC:
                raise Panic(stack.pop())
            elif op == ops.HALT:
                return
            else:
                raise AssertionError('bad opcode %d' % op)
