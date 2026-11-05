#!/usr/bin/env python3
"""Reference bigint calculator: one "<a> <op> <b>" query per stdin line.

Python's native int is the oracle. Formatting is canonical by construction:
str(int) never emits leading zeros or "-0". Division uses truncation toward
zero and a remainder with the sign of the dividend (C semantics), which differs
from Python's floor semantics, so those are derived explicitly.
"""
import sys

# Python >= 3.11 refuses int<->str conversions above 4300 digits by default;
# operands here reach 50,000 digits and results 100,000.
if hasattr(sys, "set_int_max_str_digits"):
    sys.set_int_max_str_digits(0)


def truncdiv(a, b):
    q = abs(a) // abs(b)
    return -q if (a < 0) != (b < 0) else q


def truncmod(a, b):
    r = abs(a) % abs(b)
    return -r if a < 0 else r


def solve(a, op, b):
    if op == "+":
        return a + b
    if op == "-":
        return a - b
    if op == "*":
        return a * b
    if op == "/":
        return "error" if b == 0 else truncdiv(a, b)
    if op == "%":
        return "error" if b == 0 else truncmod(a, b)
    if op == "^":
        return "error" if b < 0 else a ** b
    if op == "cmp":
        return (a > b) - (a < b)
    raise ValueError("unknown op " + op)


def main():
    out = []
    for line in sys.stdin.read().split("\n"):
        line = line.strip()
        if not line:
            continue
        a, op, b = line.split(" ")
        out.append(str(solve(int(a), op, int(b))))
    sys.stdout.write("\n".join(out) + ("\n" if out else ""))


if __name__ == "__main__":
    main()
