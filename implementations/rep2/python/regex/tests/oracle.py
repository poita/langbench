"""A direct, recursive transcription of SPEC.md section 3 over the syntax tree.

Slow and recursion-hungry, but obviously faithful; used to cross-check the VM.
"""

from btregex.ast import Alt, Any, Bol, Char, CharSet, Eol, Group, Seq, Repeat
from btregex.parser import parse


def oracle_search(pattern, s):
    tree, ngroups = parse(pattern)
    n = len(s)
    caps = [None] * (ngroups + 1)

    def m(node, i, k):
        if isinstance(node, Char):
            return i < n and s[i] == node.char and k(i + 1)
        if isinstance(node, Any):
            return i < n and k(i + 1)
        if isinstance(node, CharSet):
            return i < n and s[i] in node.chars and k(i + 1)
        if isinstance(node, Bol):
            return i == 0 and k(i)
        if isinstance(node, Eol):
            return i == n and k(i)
        if isinstance(node, Seq):
            def seq(idx, i):
                if idx == len(node.items):
                    return k(i)
                return m(node.items[idx], i, lambda j: seq(idx + 1, j))
            return seq(0, i)
        if isinstance(node, Alt):
            return any(m(b, i, k) for b in node.branches)
        if isinstance(node, Group):
            def done(j):
                old = caps[node.index]
                caps[node.index] = (i, j)
                if k(j):
                    return True
                caps[node.index] = old
                return False
            return m(node.child, i, done)
        if isinstance(node, Repeat):
            hi = node.max if node.max is not None else float("inf")

            def rep(i, count):
                if count < node.min:
                    return m(node.child, i, lambda j: rep(j, count + 1))
                if count == hi:
                    return k(i)
                if m(node.child, i,
                     lambda j: k(j) if j == i else rep(j, count + 1)):
                    return True
                return k(i)
            return rep(i, 0)
        raise TypeError(node)

    for start in range(n + 1):
        caps[:] = [None] * (ngroups + 1)
        ends = []
        if m(tree, start, lambda j: ends.append(j) or True):
            return (start, ends[0]), tuple(caps[1:])
    return None
