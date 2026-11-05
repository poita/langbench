#!/usr/bin/env python3
"""Reference implementation for the `diff` problem.

Mode "diff": computes a shortest edit script between two line sequences with
Myers' O(ND) algorithm (forward search with a saved V array per D-step and a
backtrack over the saved arrays), after trimming the common prefix and suffix.
Mode "patch": applies an edit script to a file.
"""
import sys


def myers_core(a, b):
    """Return a list of (tag, text) ops turning a into b with the minimum number
    of '-'/'+' ops, where a and b are lists of interned ints (line ids). Only
    the ids are compared; callers map ids back to text."""
    n, m = len(a), len(b)
    if n == 0:
        return [("+", y) for y in b]
    if m == 0:
        return [("-", x) for x in a]

    max_d = n + m
    off = max_d + 1
    v = [0] * (2 * off + 1)
    v[off + 1] = 0
    trace = []
    found = False
    for d in range(max_d + 1):
        # Save the diagonals k = -d-1 .. d+1 as they stand before step d; the
        # backtrack reads entries with |k| <= d-1 plus v[1] at d = 0.
        trace.append(v[off - d - 1 : off + d + 2])
        for k in range(-d, d + 1, 2):
            if k == -d or (k != d and v[off + k - 1] < v[off + k + 1]):
                x = v[off + k + 1]
            else:
                x = v[off + k - 1] + 1
            y = x - k
            while x < n and y < m and a[x] == b[y]:
                x += 1
                y += 1
            v[off + k] = x
            if x >= n and y >= m:
                found = True
                break
        if found:
            break

    ops = []
    x, y = n, m
    for d in range(len(trace) - 1, -1, -1):
        s = trace[d]
        base = d + 1  # s[base + k] is the saved v[k]
        k = x - y
        if d == 0:
            prev_x, prev_y = 0, 0
        else:
            if k == -d or (k != d and s[base + k - 1] < s[base + k + 1]):
                prev_k = k + 1
            else:
                prev_k = k - 1
            prev_x = s[base + prev_k]
            prev_y = prev_x - prev_k
        while x > prev_x and y > prev_y:
            x -= 1
            y -= 1
            ops.append((" ", a[x]))
        if d > 0:
            if x == prev_x:
                ops.append(("+", b[prev_y]))
            else:
                ops.append(("-", a[prev_x]))
        x, y = prev_x, prev_y
    ops.reverse()
    return ops


def diff(a_lines, b_lines):
    ids = {}
    a = [ids.setdefault(s, len(ids)) for s in a_lines]
    b = [ids.setdefault(s, len(ids)) for s in b_lines]
    text = [None] * len(ids)
    for s, i in ids.items():
        text[i] = s

    n, m = len(a), len(b)
    pre = 0
    while pre < n and pre < m and a[pre] == b[pre]:
        pre += 1
    suf = 0
    while suf < n - pre and suf < m - pre and a[n - 1 - suf] == b[m - 1 - suf]:
        suf += 1

    ops = [(" ", x) for x in a[:pre]]
    ops += myers_core(a[pre : n - suf], b[pre : m - suf])
    ops += [(" ", x) for x in a[n - suf :]]
    return [tag + text[i] for tag, i in ops]


def patch(a_lines, script):
    out = []
    ai = 0
    for line in script:
        tag, text = line[0], line[1:]
        if tag == " ":
            out.append(a_lines[ai])
            ai += 1
        elif tag == "-":
            ai += 1
        else:
            out.append(text)
    return out


def main():
    data = sys.stdin.buffer.read().decode("utf-8").split("\n")
    pos = 0

    def next_line():
        nonlocal pos
        line = data[pos]
        pos += 1
        return line

    def read_block():
        count = int(next_line().strip())
        return [next_line() for _ in range(count)]

    mode = next_line().strip()
    a_lines = read_block()
    second = read_block()
    if mode == "diff":
        result = diff(a_lines, second)
    else:
        result = patch(a_lines, second)
    out = [str(len(result))] + result
    sys.stdout.write("\n".join(out) + "\n")


if __name__ == "__main__":
    main()
