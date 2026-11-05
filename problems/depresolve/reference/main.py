#!/usr/bin/env python3
"""Reference solver for the `depresolve` problem.

Parses the registry and root manifest from stdin and runs the depth-first,
newest-first, chronologically backtracking resolution that SPEC.md specifies.
The search is iterative (an explicit stack of choice points plus an undo
trail) so that very deep dependency chains do not exhaust the call stack, but
it visits exactly the same states in the same order as the recursive
formulation in the spec.
"""
import sys


def parse_version(s):
    a, b, c = s.split(".")
    return (int(a), int(b), int(c))


def parse_range(s):
    """Return the range as a list of (op, version) comparators that must all
    hold; the empty list is the wildcard."""
    if s == "*":
        return []
    if s[0] == "^":
        v = parse_version(s[1:])
        if v[0] != 0:
            hi = (v[0] + 1, 0, 0)
        elif v[1] != 0:
            hi = (0, v[1] + 1, 0)
        else:
            hi = (0, 0, v[2] + 1)
        return [(">=", v), ("<", hi)]
    if s[0] == "~":
        v = parse_version(s[1:])
        return [(">=", v), ("<", (v[0], v[1] + 1, 0))]
    if s[0] in "<>":
        comps = []
        for tok in s.split(" "):
            if tok[1] == "=":
                comps.append((tok[:2], parse_version(tok[2:])))
            else:
                comps.append((tok[:1], parse_version(tok[1:])))
        return comps
    v = parse_version(s)
    return [(">=", v), ("<=", v)]


def satisfies(v, comps):
    for op, w in comps:
        if op == ">=":
            if not v >= w:
                return False
        elif op == "<":
            if not v < w:
                return False
        elif op == "<=":
            if not v <= w:
                return False
        else:
            if not v > w:
                return False
    return True


def parse_deps(text):
    deps = []
    if text:
        for item in text.split(", "):
            name, _, rng = item.partition(" ")
            deps.append((name, parse_range(rng)))
    return deps


def parse_input(data):
    registry = {}
    root = []
    for line in data.split("\n"):
        if not line:
            continue
        head, _, tail = line.partition(":")
        deps = parse_deps(tail[1:] if tail.startswith(" ") else tail)
        if head == "root":
            root = deps
        else:
            name, ver = head.split(" ")
            registry.setdefault(name, {})[parse_version(ver)] = deps
    return registry, root


def resolve(registry, root):
    """Return the first complete solution as a dict name -> version, or None."""
    versions = {name: sorted(vs, reverse=True) for name, vs in registry.items()}
    chosen = {}
    trail = []
    # Each frame is a choice point: [name, candidates, next index, rest of
    # the pending list, trail length before the choice].
    frames = []
    # The pending requirement list is a persistent linked list (head, tail)
    # so a frame can keep the "rest" it saw without copying.
    pending = None
    for req in reversed(root):
        pending = (req, pending)

    while True:
        if pending is None:
            return chosen
        (name, comps), pending = pending
        if name in chosen:
            if satisfies(chosen[name], comps):
                continue
        else:
            cands = [v for v in versions.get(name, ()) if satisfies(v, comps)]
            frames.append([name, cands, 0, pending, len(trail)])
        # Either the requirement conflicts with an earlier choice or a new
        # choice point was opened: advance the most recent choice point that
        # still has an untried candidate, discarding exhausted ones.
        while frames:
            frame = frames[-1]
            while len(trail) > frame[4]:
                del chosen[trail.pop()]
            if frame[2] < len(frame[1]):
                v = frame[1][frame[2]]
                frame[2] += 1
                chosen[frame[0]] = v
                trail.append(frame[0])
                pending = frame[3]
                for req in reversed(registry[frame[0]][v]):
                    pending = (req, pending)
                break
            frames.pop()
        else:
            return None


def main():
    registry, root = parse_input(sys.stdin.read())
    result = resolve(registry, root)
    if result is None:
        sys.stdout.write("unsatisfiable\n")
        return
    out = []
    for name in sorted(result):
        v = result[name]
        out.append(f"{name} {v[0]}.{v[1]}.{v[2]}\n")
    sys.stdout.write("".join(out))


if __name__ == "__main__":
    main()
