#!/usr/bin/env python3
"""Verifier for the `diff` problem.

Usage: verify.py <input.in> <actual.out> [<expected.out>]

Mode "diff": the produced script must be well-formed (a count line of plain
ASCII digits followed by exactly that many lines, each prefixed ' ', '-' or
'+'), must reproduce A from
its ' '/'-' lines and B from its ' '/'+' lines, and must contain exactly the
minimum possible number of '-'/'+' lines. The minimum is recomputed here with
a bit-parallel LCS (independent of the reference) and, when an expected file
is given, cross-checked against the edit count recorded there.

Mode "patch": the output must equal the count line plus the lines obtained by
applying the script to A, compared exactly (trailing spaces included).

Exit 0 on pass; otherwise print a reason and exit 1.
"""
import sys


def fail(msg):
    print(msg)
    sys.exit(1)


def split_lines(text):
    return text.replace("\r\n", "\n").split("\n")


def parse_input(text):
    data = split_lines(text)
    pos = 0

    def block():
        nonlocal pos
        count = int(data[pos].strip())
        pos += 1
        lines = data[pos : pos + count]
        pos += count
        return lines

    mode = data[pos].strip()
    pos += 1
    a = block()
    second = block()
    return mode, a, second


def parse_count(line, what):
    """The count line is ASCII digits with no sign and no leading zeros; only
    trailing spaces or tabs are tolerated around it."""
    digits = line.rstrip(" \t")
    if digits == "" or not digits.isascii() or not digits.isdigit():
        fail(f"{what}: first output line must be a non-negative decimal integer count, got {line!r}")
    if len(digits) > 1 and digits[0] == "0":
        fail(f"{what}: count line {line!r} has a leading zero")
    return int(digits)


def parse_output(text, what):
    """Parse a count line followed by that many lines; anything after them must
    be blank. Returns the list of lines."""
    data = split_lines(text)
    count = parse_count(data[0] if data else "", what)
    if len(data) - 1 < count:
        fail(f"{what}: count line says {count} lines but only {len(data) - 1} follow")
    lines = data[1 : 1 + count]
    for extra in data[1 + count :]:
        if extra != "":
            fail(f"{what}: unexpected non-empty content after the {count} declared lines: {extra!r}")
    return lines


def lcs_length(a, b):
    """Length of the longest common subsequence via Hyyro's bit-parallel
    recurrence: one big-int update per element of b."""
    n = len(a)
    if n == 0 or not b:
        return 0
    masks = {}
    for i, x in enumerate(a):
        masks[x] = masks.get(x, 0) | (1 << i)
    full = (1 << n) - 1
    v = full
    for y in b:
        u = v & masks.get(y, 0)
        v = ((v + u) | (v - u)) & full
    return n - bin(v).count("1")


def apply_script(a, script, what):
    """Apply a script to a, checking that its ' ' and '-' lines walk through a
    exactly. Returns the resulting lines."""
    out = []
    ai = 0
    for idx, line in enumerate(script):
        if line == "":
            fail(f"{what}: script line {idx + 1} is empty; every line needs a ' ', '-' or '+' prefix")
        tag, text = line[0], line[1:]
        if tag in " -":
            if ai >= len(a):
                fail(f"{what}: script line {idx + 1} ({line!r}) consumes a line of A but A is exhausted")
            if text != a[ai]:
                fail(f"{what}: script line {idx + 1} ({line!r}) does not match A line {ai + 1} ({a[ai]!r})")
            if tag == " ":
                out.append(text)
            ai += 1
        elif tag == "+":
            out.append(text)
        else:
            fail(f"{what}: script line {idx + 1} has invalid prefix {tag!r}")
    if ai != len(a):
        fail(f"{what}: script consumes only {ai} of the {len(a)} lines of A")
    return out


def main():
    in_path, actual_path = sys.argv[1], sys.argv[2]
    expected_path = sys.argv[3] if len(sys.argv) > 3 else None

    with open(in_path, encoding="utf-8") as f:
        mode, a, second = parse_input(f.read())
    with open(actual_path, encoding="utf-8", errors="replace") as f:
        actual_text = f.read()

    if mode == "diff":
        b = second
        script = parse_output(actual_text, "diff")
        produced = apply_script(a, script, "diff")
        if produced != b:
            for i, (x, y) in enumerate(zip(produced, b)):
                if x != y:
                    fail(f"diff: applying the script gives wrong B line {i + 1}: got {x!r}, want {y!r}")
            fail(f"diff: applying the script gives {len(produced)} lines, B has {len(b)}")
        edits = sum(1 for line in script if line[0] != " ")
        minimum = len(a) + len(b) - 2 * lcs_length(a, b)
        if expected_path:
            with open(expected_path, encoding="utf-8") as f:
                exp_script = parse_output(f.read(), "expected")
            exp_edits = sum(1 for line in exp_script if line[0] != " ")
            if exp_edits != minimum:
                fail(f"harness error: expected output has {exp_edits} edits but LCS bound says {minimum}")
        if edits != minimum:
            fail(f"diff: script has {edits} edit lines but the minimum is {minimum}")
    elif mode == "patch":
        want = apply_script(a, second, "input")
        got = parse_output(actual_text, "patch")
        if got != want:
            for i, (x, y) in enumerate(zip(got, want)):
                if x != y:
                    fail(f"patch: output line {i + 1} is {x!r}, want {y!r}")
            fail(f"patch: output has {len(got)} lines, want {len(want)}")
    else:
        fail(f"harness error: unknown mode {mode!r} in input")


if __name__ == "__main__":
    main()
