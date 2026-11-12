"""The bytecode instruction set.

Each instruction is a 4-tuple ``(op, a, b, c)``; unused operands are 0.  Opcodes
are small integers; the names below are listed roughly hottest-first because the
VM dispatches with an ``if``/``elif`` chain in this order.

Stack effects use ``top`` for the top of the operand stack; locals are the
per-frame list ``loc``.  Struct and enum values are tuples whose element 0 is
the declaration's (or variant's) unique id, so payload ``i`` is element ``i+1``.

====== ============================ ============================================
op     operands                     effect
====== ============================ ============================================
LOAD   slot                         push ``loc[slot]``
CONST  value                        push the constant
STORE  slot                         ``loc[slot] = pop()``
ADD..  -                            wrapping 64-bit integer arithmetic
FADD.. -                            IEEE binary64 arithmetic
EQ/NE  -                            ``==``/``!=`` (Python semantics)
DEQ/DNE -                           structural equality that honours NaN
LT..GE -                            ordering on Int, Float, Bool, Char, Str
JUMP   target                       unconditional jump
JIF/JIT target                      pop a Bool and jump if false/true
JFK/JTK target                      ``&&``/``||``: keep the value and jump when
                                    false/true, else pop and fall through
JLT..  target                       fused compare-and-jump-if-not (pops 2)
CALL   code, argc                   call a user function
CALLV  argc                         call the closure under the arguments
CALLB  fn, argc                     call a plain built-in
CALLH  fn, argc                     call a built-in that re-enters the VM
CALLM  table, argc                  dynamic trait-method dispatch on the receiver
RET                                 return ``pop()``
RETN   k                            return ``pop()`` discarding k stack entries
MKCLOS code, n                      pop n captured values, push a closure
MKLIST/MKMAP/MKTUP/MKSTRUCT/MKENUM  build aggregates from the stack
IDXL/IDXS/IDXM, SETL/SETM           indexing and index assignment
FIELD  i / TUPGET i                 project from the top value
JNV    slot, uid, target            jump unless ``loc[slot]`` is variant ``uid``
JLEN/JLENGE slot, n, target         jump unless the list length is ==n / >=n
JNEQ   slot, const, target          jump unless ``loc[slot] == const``
LOADFIELD/LOADTUP/LOADELEM slot, i  push a component of ``loc[slot]``
LISTREST slot, i                    push a new list ``loc[slot][i:]``
FORRANGE/INCJ/FORLIST/FORSTR        loop forms (see the compiler)
NOMATCH                             panic ``no match``
RETHOST                             leave a nested ``execute`` (host re-entry)
====== ============================ ============================================
"""

NAMES = """
LOAD CONST STORE ADD SUB MUL EQ NE LT LE GT GE JUMP JIF JIT CALL RET
JLT JLE JGT JGE JEQ JNE FIELD
COPY INCJ FORRANGE FORLIST FORSTR
CALLB CALLM CALLV CALLH RETN POP POPN JFK JTK DIV MOD NEG
FADD FSUB FMUL FDIV FNEG NOT DEQ DNE
BAND BOR BXOR SHL SHR BNOT CATS CATL
MKLIST MKMAP MKTUP MKSTRUCT MKENUM MKCLOS TUPGET
IDXL IDXS IDXM SETL SETM
JNV JLEN JLENGE JNEQ LOADFIELD LOADTUP LOADELEM LISTREST
NOMATCH RETHOST
""".split()

ALL = tuple(range(len(NAMES)))
globals().update({n: i for i, n in enumerate(NAMES)})
