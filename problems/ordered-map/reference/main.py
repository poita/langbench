#!/usr/bin/env python3
"""Reference ordered map: a sorted key list with bisect plus a dict for values.

Every operation is O(log n) for the search plus O(n) memmove for insertion and
deletion, which is fast enough in CPython for 200k-command workloads and keeps
the reference trivially correct.
"""
import sys
from bisect import bisect_left, bisect_right


def main():
    lines = sys.stdin.buffer.read().split(b"\n")
    q = int(lines[0])
    keys = []
    vals = {}
    out = []
    push = out.append
    for i in range(1, q + 1):
        parts = lines[i].split(b" ")
        cmd = parts[0]
        if cmd == b"insert":
            k = int(parts[1])
            if k in vals:
                push(b"updated")
            else:
                keys.insert(bisect_left(keys, k), k)
                push(b"ok")
            vals[k] = parts[2]
        elif cmd == b"delete":
            k = int(parts[1])
            if k in vals:
                del vals[k]
                del keys[bisect_left(keys, k)]
                push(b"ok")
            else:
                push(b"missing")
        elif cmd == b"get":
            push(vals.get(int(parts[1]), b"missing"))
        elif cmd == b"size":
            push(str(len(keys)).encode())
        elif cmd == b"min":
            push(str(keys[0]).encode() if keys else b"empty")
        elif cmd == b"max":
            push(str(keys[-1]).encode() if keys else b"empty")
        elif cmd == b"floor":
            i2 = bisect_right(keys, int(parts[1]))
            push(str(keys[i2 - 1]).encode() if i2 > 0 else b"missing")
        elif cmd == b"ceil":
            i2 = bisect_left(keys, int(parts[1]))
            push(str(keys[i2]).encode() if i2 < len(keys) else b"missing")
        elif cmd == b"succ":
            i2 = bisect_right(keys, int(parts[1]))
            push(str(keys[i2]).encode() if i2 < len(keys) else b"missing")
        elif cmd == b"pred":
            i2 = bisect_left(keys, int(parts[1]))
            push(str(keys[i2 - 1]).encode() if i2 > 0 else b"missing")
        elif cmd == b"rank":
            push(str(bisect_left(keys, int(parts[1]))).encode())
        elif cmd == b"select":
            k = int(parts[1])
            push(str(keys[k]).encode() if k < len(keys) else b"missing")
        elif cmd == b"range":
            lo = int(parts[1])
            hi = int(parts[2])
            a = bisect_left(keys, lo)
            b = bisect_right(keys, hi)
            if a < b:
                push(" ".join(map(str, keys[a:b])).encode())
            else:
                push(b"empty")
        else:
            raise ValueError("unknown command: %r" % cmd)
    sys.stdout.buffer.write(b"\n".join(out) + b"\n")


if __name__ == "__main__":
    main()
