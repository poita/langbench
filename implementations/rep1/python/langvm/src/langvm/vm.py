"""The stack virtual machine (SPEC section 16).

``VM.execute`` is a flat fetch-decode-execute loop with its own frame stack, so
Vellum call depth is independent of the host's recursion depth.  Built-ins that
call closures re-enter ``execute`` through :meth:`VM.call`; the frame accounting
below keeps the 20000-frame limit exact across such re-entries.
"""

from __future__ import annotations

from . import ops as O
from .compiler import Code, Image
from .diagnostics import Panic
from .stdlib import B63, M64, fdiv, make_builtins
from .values import Char, Closure, veq

MAX_FRAMES = 20000
IMAX = B63 - 1
IMIN = -B63

_HEADS = {
    int: "Int", float: "Float", bool: "Bool", str: "Str", Char: "Char",
    type(None): "Unit", list: "List", dict: "Map",
}

_RETHOST = Code("<host>")
_RETHOST.code = [(O.RETHOST, 0, 0, 0)]


class VM:
    def __init__(self, image: Image, out: list):
        self.image = image
        self.out = out
        self.st: list = []
        self.frames: list = []
        self.nsent = 0
        self.builtins = make_builtins(self)

    # ----------------------------------------------------------- public API
    def run(self) -> None:
        """Run ``main``; raises :class:`Panic` on a run-time error."""
        main = self.image.main
        self.execute(main, list(main.pad))

    def call1(self, clo: Closure, a):
        code = clo.code
        loc = [a]
        loc += clo.up
        loc += code.pad
        return self.execute(code, loc)

    def call2(self, clo: Closure, a, b):
        code = clo.code
        loc = [a, b]
        loc += clo.up
        loc += code.pad
        return self.execute(code, loc)

    # ------------------------------------------------------------ main loop
    def execute(self, entry: Code, loc: list):
        st = self.st
        frames = self.frames
        builtins = self.builtins
        ctor_head = self.image.ctor_head
        heads = _HEADS
        push = st.append
        pop = st.pop
        self.nsent += 1
        maxf = MAX_FRAMES - 1 + self.nsent
        frames.append((_RETHOST.code, 0, None))
        code = entry.code
        pc = 0
        (LOAD, CONST, STORE, ADD, SUB, MUL, EQ, NE, LT, LE, GT, GE, JUMP, JIF, JIT, CALL, RET,
         JLT, JLE, JGT, JGE, JEQ, JNE, FIELD,
         COPY, INCJ, FORRANGE, FORLIST, FORSTR,
         CALLB, CALLM, CALLV, CALLH, RETN, POP, POPN, JFK, JTK, DIV, MOD, NEG,
         FADD, FSUB, FMUL, FDIV, FNEG, NOT, DEQ, DNE,
         BAND, BOR, BXOR, SHL, SHR, BNOT, CATS, CATL,
         MKLIST, MKMAP, MKTUP, MKSTRUCT, MKENUM, MKCLOS, TUPGET,
         IDXL, IDXS, IDXM, SETL, SETM,
         JNV, JLEN, JLENGE, JNEQ, LOADFIELD, LOADTUP, LOADELEM, LISTREST,
         NOMATCH, RETHOST) = O.ALL
        while True:
            op, a, b, c = code[pc]
            pc += 1
            if op == LOAD:
                push(loc[a])
            elif op == CONST:
                push(a)
            elif op == STORE:
                loc[a] = pop()
            elif op == ADD:
                y = pop()
                r = st[-1] + y
                if r > IMAX or r < IMIN:
                    r = ((r + B63) & M64) - B63
                st[-1] = r
            elif op == SUB:
                y = pop()
                r = st[-1] - y
                if r > IMAX or r < IMIN:
                    r = ((r + B63) & M64) - B63
                st[-1] = r
            elif op == MUL:
                y = pop()
                r = st[-1] * y
                if r > IMAX or r < IMIN:
                    r = ((r + B63) & M64) - B63
                st[-1] = r
            elif op == EQ:
                y = pop()
                st[-1] = st[-1] == y
            elif op == NE:
                y = pop()
                st[-1] = st[-1] != y
            elif op == LT:
                y = pop()
                st[-1] = st[-1] < y
            elif op == LE:
                y = pop()
                st[-1] = st[-1] <= y
            elif op == GT:
                y = pop()
                st[-1] = st[-1] > y
            elif op == GE:
                y = pop()
                st[-1] = st[-1] >= y
            elif op == JUMP:
                pc = a
            elif op == JIF:
                if not pop():
                    pc = a
            elif op == JIT:
                if pop():
                    pc = a
            elif op == CALL:
                if len(frames) >= maxf:
                    raise Panic("call stack overflow")
                frames.append((code, pc, loc))
                if b:
                    loc = st[-b:]
                    del st[-b:]
                    loc += a.pad
                else:
                    loc = a.pad[:]
                code = a.code
                pc = 0
            elif op == RET:
                r = pop()
                code, pc, loc = frames.pop()
                push(r)
            elif op == JLT:
                y = pop()
                if not pop() < y:
                    pc = c
            elif op == JLE:
                y = pop()
                if not pop() <= y:
                    pc = c
            elif op == JGT:
                y = pop()
                if not pop() > y:
                    pc = c
            elif op == JGE:
                y = pop()
                if not pop() >= y:
                    pc = c
            elif op == JEQ:
                y = pop()
                if not pop() == y:
                    pc = c
            elif op == JNE:
                y = pop()
                if not pop() != y:
                    pc = c
            elif op == FIELD:
                st[-1] = st[-1][a + 1]
            elif op == COPY:
                loc[b] = loc[a]
            elif op == INCJ:
                loc[a] += 1
                pc = b
            elif op == FORRANGE:
                i = loc[a]
                if i < loc[a + 1]:
                    if b >= 0:
                        loc[b] = i
                else:
                    pc = c
            elif op == FORLIST:
                s = loc[a]
                i = loc[a + 1]
                if i < len(s):
                    loc[a + 1] = i + 1
                    if b >= 0:
                        loc[b] = s[i]
                    else:
                        push(s[i])
                else:
                    pc = c
            elif op == FORSTR:
                s = loc[a]
                i = loc[a + 1]
                if i < len(s):
                    loc[a + 1] = i + 1
                    if b >= 0:
                        loc[b] = Char(s[i])
                    else:
                        push(Char(s[i]))
                else:
                    pc = c
            elif op == CALLB:
                f = builtins[a]
                if b == 1:
                    st[-1] = f(st[-1])
                elif b == 2:
                    y = pop()
                    st[-1] = f(st[-1], y)
                elif b == 0:
                    push(f())
                elif b == 3:
                    z = pop()
                    y = pop()
                    st[-1] = f(st[-1], y, z)
                else:
                    args = st[-b:]
                    del st[-b:]
                    push(f(*args))
            elif op == CALLM:
                recv = st[-b - 1]
                if type(recv) is tuple:
                    f = a[ctor_head[recv[0]]]
                else:
                    f = a[heads[type(recv)]]
                if len(frames) >= maxf:
                    raise Panic("call stack overflow")
                frames.append((code, pc, loc))
                n = b + 1
                loc = st[-n:]
                del st[-n:]
                loc += f.pad
                code = f.code
                pc = 0
            elif op == CALLV:
                clo = st[-b - 1]
                f = clo.code
                if len(frames) >= maxf:
                    raise Panic("call stack overflow")
                frames.append((code, pc, loc))
                if b:
                    loc = st[-b:]
                    del st[-b - 1:]
                else:
                    loc = []
                    pop()
                loc += clo.up
                loc += f.pad
                code = f.code
                pc = 0
            elif op == CALLH:
                f = builtins[a]
                frames.append((code, pc, loc))
                args = st[-b:]
                del st[-b:]
                r = f(*args)
                frames.pop()
                push(r)
            elif op == RETN:
                r = pop()
                del st[-a:]
                code, pc, loc = frames.pop()
                push(r)
            elif op == POP:
                pop()
            elif op == POPN:
                del st[-a:]
            elif op == JFK:
                if not st[-1]:
                    pc = a
                else:
                    pop()
            elif op == JTK:
                if st[-1]:
                    pc = a
                else:
                    pop()
            elif op == DIV:
                y = pop()
                if y == 0:
                    raise Panic("divide by zero")
                x = st[-1]
                if x >= 0 and y > 0:
                    st[-1] = x // y
                else:
                    q = abs(x) // abs(y)
                    if (x < 0) != (y < 0):
                        q = -q
                    st[-1] = q if q <= IMAX else IMIN
            elif op == MOD:
                y = pop()
                if y == 0:
                    raise Panic("modulo by zero")
                x = st[-1]
                if x >= 0 and y > 0:
                    st[-1] = x % y
                else:
                    r = abs(x) % abs(y)
                    st[-1] = -r if x < 0 else r
            elif op == NEG:
                r = -st[-1]
                st[-1] = r if r <= IMAX else IMIN
            elif op == FADD:
                y = pop()
                st[-1] += y
            elif op == FSUB:
                y = pop()
                st[-1] -= y
            elif op == FMUL:
                y = pop()
                st[-1] *= y
            elif op == FDIV:
                y = pop()
                st[-1] = fdiv(st[-1], y)
            elif op == FNEG:
                st[-1] = -st[-1]
            elif op == NOT:
                st[-1] = not st[-1]
            elif op == DEQ:
                y = pop()
                st[-1] = veq(st[-1], y)
            elif op == DNE:
                y = pop()
                st[-1] = not veq(st[-1], y)
            elif op == BAND:
                y = pop()
                st[-1] &= y
            elif op == BOR:
                y = pop()
                st[-1] |= y
            elif op == BXOR:
                y = pop()
                st[-1] ^= y
            elif op == SHL:
                y = pop()
                if y < 0 or y > 63:
                    raise Panic("shift amount out of range")
                r = st[-1] << y
                st[-1] = ((r + B63) & M64) - B63
            elif op == SHR:
                y = pop()
                if y < 0 or y > 63:
                    raise Panic("shift amount out of range")
                st[-1] >>= y
            elif op == BNOT:
                st[-1] = ~st[-1]
            elif op == CATS:
                y = pop()
                st[-1] += y
            elif op == CATL:
                y = pop()
                st[-1] = st[-1] + y
            elif op == MKLIST:
                if b:
                    r = st[-b:]
                    del st[-b:]
                    push(r)
                else:
                    push([])
            elif op == MKMAP:
                if a:
                    items = st[-2 * a:]
                    del st[-2 * a:]
                    push(dict(zip(items[::2], items[1::2])))
                else:
                    push({})
            elif op == MKTUP:
                r = tuple(st[-b:])
                del st[-b:]
                push(r)
            elif op == MKSTRUCT:
                if b:
                    vals = st[-b:]
                    del st[-b:]
                    if c:
                        push((a,) + tuple([vals[i] for i in c]))
                    else:
                        push((a,) + tuple(vals))
                else:
                    push((a,))
            elif op == MKENUM:
                r = (a,) + tuple(st[-b:])
                del st[-b:]
                push(r)
            elif op == MKCLOS:
                if b:
                    up = tuple(st[-b:])
                    del st[-b:]
                else:
                    up = ()
                push(Closure(a, up))
            elif op == TUPGET:
                st[-1] = st[-1][a]
            elif op == IDXL:
                i = pop()
                lst = st[-1]
                if i < 0 or i >= len(lst):
                    raise Panic("index out of bounds")
                st[-1] = lst[i]
            elif op == IDXS:
                i = pop()
                s = st[-1]
                if i < 0 or i >= len(s):
                    raise Panic("index out of bounds")
                st[-1] = Char(s[i])
            elif op == IDXM:
                k = pop()
                m = st[-1]
                if k not in m:
                    raise Panic("missing key")
                st[-1] = m[k]
            elif op == SETL:
                v = pop()
                i = pop()
                lst = pop()
                if i < 0 or i >= len(lst):
                    raise Panic("index out of bounds")
                lst[i] = v
            elif op == SETM:
                v = pop()
                k = pop()
                pop()[k] = v
            elif op == JNV:
                if loc[a][0] != b:
                    pc = c
            elif op == JLEN:
                if len(loc[a]) != b:
                    pc = c
            elif op == JLENGE:
                if len(loc[a]) < b:
                    pc = c
            elif op == JNEQ:
                if loc[a] != b:
                    pc = c
            elif op == LOADFIELD:
                push(loc[a][b + 1])
            elif op == LOADTUP or op == LOADELEM:
                push(loc[a][b])
            elif op == LISTREST:
                push(loc[a][b:])
            elif op == NOMATCH:
                raise Panic("no match")
            elif op == RETHOST:
                self.nsent -= 1
                return pop()
            else:  # pragma: no cover
                raise AssertionError(f"bad opcode {op}")
