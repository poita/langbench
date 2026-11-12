"""Independent reference implementation used only by the tests.

It uses the host's double-precision arithmetic, which is exact enough for
binary32 operands: rounding a correctly rounded double to binary32 gives the
correctly rounded binary32 result for + - * / and sqrt (53 >= 2*24 + 2).
"""

import math
import struct

QNAN = 0x7FC00000


def to_float(bits):
    return struct.unpack(">f", struct.pack(">I", bits))[0]


def from_float(x):
    if math.isnan(x):
        return QNAN
    try:
        return struct.unpack(">I", struct.pack(">f", x))[0]
    except OverflowError:
        return 0xFF800000 if x < 0 else 0x7F800000


def _sign(bits):
    return bits >> 31


def reference(op, a, b=0):
    x, y = to_float(a), to_float(b)
    if math.isnan(x) or (op != "sqrt" and math.isnan(y)):
        return QNAN
    if op == "add":
        if x == 0 and y == 0:
            return a & b & 0x80000000
        return from_float(x + y) if x + y != 0 else 0
    if op == "sub":
        return reference("add", a, b ^ 0x80000000)
    if op == "mul":
        r = from_float(x * y)
        return r if r != QNAN else QNAN
    if op == "div":
        if y == 0:
            if x == 0:
                return QNAN
            return ((_sign(a) ^ _sign(b)) << 31) | 0x7F800000
        return from_float(x / y)
    if op == "sqrt":
        if x == 0:
            return a
        if x < 0:
            return QNAN
        return from_float(math.sqrt(x))
    raise ValueError(op)
