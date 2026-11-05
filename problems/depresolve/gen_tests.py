#!/usr/bin/env python3
"""Generate tests/*.in and tests/*.out for the `depresolve` problem.

Hand-written edge cases are embedded as literals; structured families (deep
chains, backtracking stress, lockfile-style registries, large consistent
registries with wide fans) and fully random small registries are produced
with fixed seeds. Every expected output comes from reference/main.py and is
cross-checked against an independent oracle: a direct recursive transcription
of the pseudo-code in SPEC.md, run with a large thread stack. Any
disagreement aborts generation.
"""
import os
import random
import re
import subprocess
import sys
import threading

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.join(HERE, "tests")
REF = os.path.join(HERE, "reference", "main.py")


def fmt(v):
    return f"{v[0]}.{v[1]}.{v[2]}"


# -- independent oracle ------------------------------------------------------
# A literal transcription of the algorithm in SPEC.md: recursive, with the
# chosen map copied at every choice so backtracking is implicit. The pending
# list is a linked list (head, tail) purely so prepending is cheap.

def o_parse_version(s):
    a, b, c = s.split(".")
    return (int(a), int(b), int(c))


def o_range_pred(s):
    """Return a predicate on version tuples for the range text s."""
    if s == "*":
        return lambda v: True
    if s[0] == "^":
        lo = o_parse_version(s[1:])
        if lo[0] > 0:
            hi = (lo[0] + 1, 0, 0)
        elif lo[1] > 0:
            hi = (0, lo[1] + 1, 0)
        else:
            hi = (0, 0, lo[2] + 1)
        return lambda v: lo <= v < hi
    if s[0] == "~":
        lo = o_parse_version(s[1:])
        hi = (lo[0], lo[1] + 1, 0)
        return lambda v: lo <= v < hi
    if s[0] in "<>":
        preds = []
        for tok in s.split(" "):
            if tok.startswith(">="):
                w = o_parse_version(tok[2:])
                preds.append(lambda v, w=w: v >= w)
            elif tok.startswith("<="):
                w = o_parse_version(tok[2:])
                preds.append(lambda v, w=w: v <= w)
            elif tok.startswith(">"):
                w = o_parse_version(tok[1:])
                preds.append(lambda v, w=w: v > w)
            else:
                w = o_parse_version(tok[1:])
                preds.append(lambda v, w=w: v < w)
        return lambda v: all(p(v) for p in preds)
    exact = o_parse_version(s)
    return lambda v: v == exact


def o_parse(text):
    registry = {}
    root = []
    for line in text.split("\n"):
        if not line:
            continue
        head, _, tail = line.partition(": ")
        if not tail and line.endswith(":"):
            head = line[:-1]
        deps = []
        if tail:
            for item in tail.split(", "):
                name, _, rng = item.partition(" ")
                deps.append((name, o_range_pred(rng)))
        if head == "root":
            root = deps
        else:
            name, ver = head.split(" ")
            registry.setdefault(name, {})[o_parse_version(ver)] = deps
    return registry, root


def oracle(text):
    registry, root = o_parse(text)
    FAIL = None

    def resolve(pending, chosen):
        if pending is None:
            return chosen
        (name, ok), rest = pending
        if name in chosen:
            if ok(chosen[name]):
                return resolve(rest, chosen)
            return FAIL
        for version in sorted((v for v in registry.get(name, {}) if ok(v)), reverse=True):
            new_pending = rest
            for req in reversed(registry[name][version]):
                new_pending = (req, new_pending)
            new_chosen = dict(chosen)
            new_chosen[name] = version
            result = resolve(new_pending, new_chosen)
            if result is not FAIL:
                return result
        return FAIL

    pending = None
    for req in reversed(root):
        pending = (req, pending)
    answer = resolve(pending, {})
    if answer is None:
        return "unsatisfiable\n"
    return "".join(f"{n} {fmt(answer[n])}\n" for n in sorted(answer))


# -- input grammar check ------------------------------------------------------
# Every generated input must match the grammar in SPEC.md exactly; the
# reference and the oracle are more tolerant than an implementer needs to be.

_V = r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)"
_CMP = r"(?:<=|>=|<|>)" + _V
_RANGE = rf"(?:\*|{_V}|\^{_V}|~{_V}|{_CMP}(?: {_CMP}){{0,2}})"
_REQ = rf"[a-z][a-z0-9-]{{0,15}} {_RANGE}"
_REQS = rf"(?: {_REQ}(?:, {_REQ})*)?"
_REG_LINE = re.compile(rf"([a-z][a-z0-9-]{{0,15}}) ({_V}):({_REQS})")
_ROOT_LINE = re.compile(rf"root:({_REQS})")


def validate(text):
    assert text.endswith("\n") and "\r" not in text
    assert all(32 <= ord(ch) < 127 or ch == "\n" for ch in text)
    lines = text.split("\n")[:-1]
    assert lines, "no root line"
    seen = set()
    for i, line in enumerate(lines):
        if i == len(lines) - 1:
            m = _ROOT_LINE.fullmatch(line)
            assert m, ("bad root line", line)
            reqs = m.group(1)
        else:
            m = _REG_LINE.fullmatch(line)
            assert m, ("bad registry line", line)
            name, ver, reqs = m.groups()
            assert name != "root" and (name, ver) not in seen, line
            seen.add((name, ver))
        names = [item.split(" ")[0] for item in reqs[1:].split(", ")] if reqs else []
        assert len(names) == len(set(names)), ("duplicate requirement", line)
        assert "root" not in names, line
        for item in reqs[1:].split(", ") if reqs else []:
            for num in re.findall(r"[0-9]+", item):
                assert int(num) <= 1_000_000, line


def oracle_in_big_stack(text):
    out = {}

    def run():
        sys.setrecursionlimit(10_000_000)
        out["v"] = oracle(text)

    threading.stack_size(1024 * 1024 * 1024)
    t = threading.Thread(target=run)
    t.start()
    t.join()
    return out["v"]


# -- hand-written edge cases -------------------------------------------------

HAND = [
    ("empty_root",
     "a 1.0.0:\n"
     "root:\n"),
    ("empty_registry",
     "root: a *\n"),
    ("single_exact",
     "a 1.0.0:\n"
     "a 1.1.0:\n"
     "root: a 1.0.0\n"),
    ("newest_first_numeric",
     "a 1.9.0:\n"
     "a 1.10.0:\n"
     "a 1.2.0:\n"
     "a 0.9.9:\n"
     "root: a *\n"),
    ("caret_major",
     "a 1.2.2:\n"
     "a 1.2.3:\n"
     "a 1.9.0:\n"
     "a 2.0.0:\n"
     "root: a ^1.2.3\n"),
    ("caret_zero_minor",
     "a 0.2.2:\n"
     "a 0.2.3:\n"
     "a 0.2.9:\n"
     "a 0.3.0:\n"
     "root: a ^0.2.3\n"),
    ("caret_zero_zero",
     "a 0.0.2:\n"
     "a 0.0.3:\n"
     "a 0.0.4:\n"
     "b 0.0.0:\n"
     "b 0.0.1:\n"
     "c 0.1.0:\n"
     "c 0.1.5:\n"
     "c 0.2.0:\n"
     "root: a ^0.0.3, b ^0.0.0, c ^0.1.0\n"),
    ("tilde",
     "a 1.2.2:\n"
     "a 1.2.3:\n"
     "a 1.2.9:\n"
     "a 1.3.0:\n"
     "b 0.0.3:\n"
     "b 0.0.9:\n"
     "b 0.1.0:\n"
     "root: a ~1.2.3, b ~0.0.3\n"),
    ("comparators",
     "a 1.0.0:\n"
     "a 1.5.0:\n"
     "a 2.0.0:\n"
     "b 1.0.0:\n"
     "b 1.0.1:\n"
     "c 0.9.0:\n"
     "c 1.0.0:\n"
     "c 1.0.1:\n"
     "d 0.5.0:\n"
     "d 0.6.0:\n"
     "d 0.9.0:\n"
     "d 1.0.0:\n"
     "e 0.1.0:\n"
     "e 1.0.0:\n"
     "root: a >=1.0.0 <2.0.0, b >1.0.0, c <=1.0.0, d >0.5.0 <=1.0.0 <0.9.0, e <1.0.0\n"),
    ("missing_package",
     "a 1.0.0:\n"
     "root: a *, zz *\n"),
    ("no_matching_version",
     "a 1.0.0:\n"
     "a 1.5.0:\n"
     "root: a ^2.0.0\n"),
    ("empty_comparator_range",
     "a 1.0.0:\n"
     "a 1.5.0:\n"
     "root: a >=1.5.0 <1.0.0\n"),
    ("diamond_compatible",
     "a 1.0.0: c ^1.0.0\n"
     "b 1.0.0: c >=1.2.0\n"
     "c 1.1.0:\n"
     "c 1.2.5:\n"
     "c 1.3.0:\n"
     "root: a *, b *\n"),
    ("diamond_backtrack",
     "a 1.0.0: c ^1.0.0\n"
     "b 1.0.0: c ~1.2.0\n"
     "c 1.1.0:\n"
     "c 1.2.5:\n"
     "c 1.3.0:\n"
     "root: a *, b *\n"),
    ("conflicting_majors",
     "a 1.0.0: c ^1.0.0\n"
     "b 1.0.0: c ^2.0.0\n"
     "c 1.0.0:\n"
     "c 2.0.0:\n"
     "root: a *, b *\n"),
    ("backtrack_older_major",
     "a 2.0.0: c ^2.0.0\n"
     "a 1.0.0: c ^1.0.0\n"
     "b 1.0.0: c ^1.0.0\n"
     "c 1.0.0:\n"
     "c 2.0.0:\n"
     "root: a *, b *\n"),
    ("order_matters_ab",
     "a 2.0.0: c ^2.0.0\n"
     "a 1.0.0: c ^1.0.0\n"
     "b 2.0.0: c ^1.0.0\n"
     "b 1.0.0: c ^2.0.0\n"
     "c 1.0.0:\n"
     "c 2.0.0:\n"
     "root: a *, b *\n"),
    ("order_matters_ba",
     "a 2.0.0: c ^2.0.0\n"
     "a 1.0.0: c ^1.0.0\n"
     "b 2.0.0: c ^1.0.0\n"
     "b 1.0.0: c ^2.0.0\n"
     "c 1.0.0:\n"
     "c 2.0.0:\n"
     "root: b *, a *\n"),
    ("cycle",
     "a 1.0.0: b ^1.0.0\n"
     "b 1.0.0: a ^1.0.0\n"
     "root: a *\n"),
    ("cycle_backtrack",
     "a 1.0.0: b *\n"
     "a 2.0.0: b *\n"
     "b 1.0.0: a ^1.0.0\n"
     "root: a *\n"),
    ("self_dependency",
     "a 2.0.0: a ^1.0.0\n"
     "a 1.0.0: a ^1.0.0\n"
     "b 1.0.0: b 1.0.0\n"
     "root: a *, b *\n"),
    ("reencounter_rejects",
     "a 1.0.0: b *\n"
     "b 1.0.0:\n"
     "b 2.0.0:\n"
     "root: a *, b ^1.0.0\n"),
    ("not_globally_newest",
     "a 2.0.0: b ~1.0.0\n"
     "a 1.0.0:\n"
     "b 1.0.0:\n"
     "b 1.0.5:\n"
     "b 1.5.0:\n"
     "b 2.0.0:\n"
     "root: a *, b *\n"),
    ("unsat_exhaustive",
     "a 1.0.0:\n"
     "a 2.0.0:\n"
     "a 3.0.0:\n"
     "b 1.0.0:\n"
     "b 2.0.0:\n"
     "c 1.0.0: a ^9.0.0\n"
     "root: a *, b *, c *\n"),
    ("unreachable_ignored",
     "a 1.0.0:\n"
     "x 1.0.0: nonexistent *\n"
     "y 1.0.0: a ^5.0.0\n"
     "root: a *\n"),
    ("deps_of_unchosen_versions",
     "a 2.0.0:\n"
     "a 1.0.0: b *\n"
     "b 1.0.0:\n"
     "root: a *\n"),
    ("first_requirement_decides",
     "a 1.0.0: d ^1.0.0\n"
     "b 1.0.0: d ^1.2.0\n"
     "c 1.0.0: d >=1.0.0\n"
     "d 1.0.0:\n"
     "d 1.2.0:\n"
     "d 1.4.0:\n"
     "d 2.0.0:\n"
     "root: a *, b *, c *\n"),
    ("names_and_sorting",
     "my-lib 1.0.0: mylib ^2.0.0\n"
     "my-lib2 0.4.0:\n"
     "mylib 2.3.1: my-lib2 *, z9 ~0.0.1\n"
     "mylib 3.0.0:\n"
     "z9 0.0.1:\n"
     "z9 0.0.2:\n"
     "a1 7.7.7:\n"
     "root: my-lib *, a1 >=7.0.0\n"),
    ("large_components",
     "a 1.99.0:\n"
     "a 1.100.0:\n"
     "a 1.100.1000000:\n"
     "a 9.0.0:\n"
     "a 10.0.0:\n"
     "b 0.0.999999:\n"
     "b 0.0.1000000:\n"
     "root: a >=1.100.0 <10.0.0, b ^0.0.999999\n"),
    ("exact_after_caret",
     "a 1.0.0: c ^1.0.0\n"
     "b 1.0.0: c 1.5.0\n"
     "b 2.0.0: c 1.4.0\n"
     "c 1.4.0:\n"
     "c 1.5.0:\n"
     "c 1.6.0:\n"
     "root: a *, b *\n"),
    ("backtrack_into_subtree",
     "a 3.0.0: x 3.0.0, y 3.0.0\n"
     "a 2.0.0: x 2.0.0, y 2.0.0\n"
     "a 1.0.0: x 1.0.0, y 1.0.0\n"
     "x 1.0.0: y ^1.0.0\n"
     "x 2.0.0: y ^2.0.0\n"
     "x 3.0.0: y ^3.0.0\n"
     "y 1.0.0:\n"
     "y 2.0.0:\n"
     "y 3.0.0:\n"
     "b 1.0.0: y <2.0.0\n"
     "root: a *, b *\n"),
    # Every comparator operator with a version sitting exactly on the bound,
    # placed so that the strictness of the bound changes the resolution.
    ("comparator_boundaries",
     "a 1.0.0:\n"
     "a 1.5.0:\n"
     "a 2.0.0:\n"
     "b 1.0.0:\n"
     "b 1.5.0:\n"
     "c 0.9.0:\n"
     "c 1.0.0:\n"
     "w 1.0.0: c >1.0.0\n"
     "w 0.9.0: c >0.9.0\n"
     "d 1.0.0:\n"
     "d 2.0.0:\n"
     "x 2.0.0: d >=2.0.0\n"
     "x 1.0.0: d >=1.0.0\n"
     "root: a <1.5.0, b <=1.5.0, w *, x *\n"),
    # The requirements of one registry line are processed in the order
    # written: b is fixed before c is looked at.
    ("line_order_matters",
     "a 1.0.0: b *, c *\n"
     "b 2.0.0: d ^2.0.0\n"
     "b 1.0.0: d ^1.0.0\n"
     "c 2.0.0: d ^1.0.0\n"
     "c 1.0.0: d ^2.0.0\n"
     "d 1.0.0:\n"
     "d 2.0.0:\n"
     "root: a *\n"),
    # A chosen version's requirements go in front of the remaining pending
    # requirements: a's `c *` fixes c before the root's `b *` is reached, so
    # b has to step down; appending them instead would fix b 2.0.0 first.
    ("chosen_reqs_go_first",
     "a 1.0.0: c *\n"
     "b 2.0.0: c 1.0.0\n"
     "b 1.0.0: c 2.0.0\n"
     "c 1.0.0:\n"
     "c 2.0.0:\n"
     "root: a *, b *\n"),
]


# -- structured families ----------------------------------------------------

def deep_chain(n):
    """A chain p0 -> p1 -> ... -> p(n-1), each with one version except the
    tail, which has two. Root then pins the tail to its older version, so the
    search must unwind n single-candidate frames to retry the tail."""
    lines = []
    for i in range(n - 1):
        lines.append(f"p{i:04d} 1.0.0: p{i + 1:04d} ^1.0.0")
    lines.append(f"p{n - 1:04d} 1.0.0:")
    lines.append(f"p{n - 1:04d} 1.1.0:")
    lines.append(f"root: p0000 *, p{n - 1:04d} 1.0.0")
    return "\n".join(lines) + "\n"


def many_versions(n, seed):
    """One package with n versions listed in random order; the root asks for
    a narrow window near the bottom, plus a second requirement that forces
    backtracking through most of the versions."""
    r = random.Random(seed)
    vers = []
    cur = (0, 1, 0)
    while len(vers) < n:
        vers.append(cur)
        k = r.random()
        if k < 0.7:
            cur = (cur[0], cur[1], cur[2] + 1)
        elif k < 0.95:
            cur = (cur[0], cur[1] + 1, 0)
        else:
            cur = (cur[0] + 1, 0, 0)
    order = vers[:]
    r.shuffle(order)
    lines = [f"lib {fmt(v)}:" for v in order]
    # app requires the 5th-oldest version exactly; root asks for lib first
    # with a wide range so the search walks the versions newest-first.
    target = vers[4]
    lines.append(f"app 1.0.0: lib {fmt(target)}")
    lines.append(f"root: lib >={fmt(vers[0])}, app *")
    return "\n".join(lines) + "\n"


def bt_stress(levels, nver):
    """levels packages with nver versions each, all unconstrained, followed by
    a sink that accepts only versions <= 3.0.0 of each. Chronological
    backtracking enumerates a large product of combinations before the
    all-3.0.0 solution is reached."""
    lines = []
    for i in range(1, levels + 1):
        for k in range(1, nver + 1):
            lines.append(f"p{i} {k}.0.0:")
    lines.append("sink 1.0.0: " + ", ".join(f"p{i} <=3.0.0" for i in range(1, levels + 1)))
    lines.append("root: " + ", ".join(f"p{i} *" for i in range(1, levels + 1)) + ", sink *")
    return "\n".join(lines) + "\n"


def subtree_retry(nver, width):
    """Package a has nver versions; each version pulls in its own exact
    subtree of `width` packages, and the last subtree package requires a
    version of `shared` matching a's major. Root then demands shared 1.x, so
    every subtree of a's newer versions is built and torn down."""
    lines = []
    for k in range(1, nver + 1):
        lines.append(f"a {k}.0.0: s{k}-0 {k}.0.0")
        for j in range(width):
            nxt = f"s{k}-{j + 1} {k}.0.0" if j + 1 < width else f"shared ^{k}.0.0"
            lines.append(f"s{k}-{j} {k}.0.0: {nxt}")
        lines.append(f"shared {k}.0.0:")
    lines.append("root: a *, shared ^1.0.0")
    return "\n".join(lines) + "\n"


def gen_versions(r, n):
    vs = set()
    cur = (r.choice([0, 0, 1, 1, 2]), r.randrange(0, 4), r.randrange(0, 5))
    while len(vs) < n:
        vs.add(cur)
        k = r.random()
        if k < 0.6:
            cur = (cur[0], cur[1], cur[2] + r.randrange(1, 4))
        elif k < 0.9:
            cur = (cur[0], cur[1] + r.randrange(1, 3), r.randrange(0, 3))
        else:
            cur = (cur[0] + 1, r.randrange(0, 2), r.randrange(0, 3))
    return sorted(vs)


def rand_range(r, vs):
    """An arbitrary range in the language, anchored on existing versions but
    not guaranteed to match anything."""
    t = r.choice(vs)
    k = r.random()
    if k < 0.08:
        return "*"
    if k < 0.18:
        return fmt(t)
    if k < 0.55:
        return "^" + fmt(t)
    if k < 0.75:
        return "~" + fmt(t)
    lo = r.choice(vs)
    hi = r.choice(vs)
    forms = [f">={fmt(lo)} <{fmt(hi)}", f">={fmt(lo)}", f"<{fmt(hi)}", f">{fmt(lo)} <={fmt(hi)}"]
    return r.choice(forms)


def random_registry(seed, npk, nver, fan, nroot):
    """Fully random layered registry: package i depends on a random subset of
    packages with larger index, with arbitrary ranges."""
    r = random.Random(seed)
    names = [f"p{i:03d}" for i in range(npk)]
    vers = {n: gen_versions(r, nver) for n in names}
    lines = []
    for i, n in enumerate(names):
        for v in vers[n]:
            cands = names[i + 1:]
            k = min(len(cands), r.randrange(0, fan + 1))
            deps = r.sample(cands, k)
            deps.sort(key=lambda d: names.index(d))
            r.shuffle(deps)
            parts = [f"{d} {rand_range(r, vers[d])}" for d in deps]
            lines.append(f"{n} {fmt(v)}:" + (" " + ", ".join(parts) if parts else ""))
    rootdeps = r.sample(names[:20], nroot)
    parts = [f"{d} {rand_range(r, vers[d])}" for d in rootdeps]
    lines.append("root: " + ", ".join(parts))
    return "\n".join(lines) + "\n"


def range_including(r, vs, t):
    """A random range in the language that includes version t of a package
    whose sorted versions are vs (it may include other versions too)."""
    k = r.random()
    if k < 0.08:
        return "*"
    if k < 0.18:
        return fmt(t)
    if k < 0.55:
        if t[0] != 0:
            lows = [v for v in vs if v <= t and v[0] == t[0]]
        elif t[1] != 0:
            lows = [v for v in vs if v <= t and v[:2] == t[:2]]
        else:
            lows = [t]
        return "^" + fmt(r.choice(lows))
    if k < 0.72:
        lows = [v for v in vs if v <= t and v[:2] == t[:2]]
        return "~" + fmt(r.choice(lows))
    lows = [v for v in vs if v <= t]
    his = [v for v in vs if v > t]
    lo = r.choice(lows)
    forms = [f">={fmt(lo)}"]
    if his:
        hi = r.choice(his)
        forms += [f">={fmt(lo)} <{fmt(hi)}", f"<{fmt(hi)}", f">={fmt(lo)} <={fmt(t)}"]
    strict = [v for v in vs if v < t]
    if strict:
        forms.append(f">{fmt(r.choice(strict))}")
    return r.choice(forms)


def range_only(r, vs, t):
    """A random range that matches version t and no other version in vs."""
    i = vs.index(t)
    forms = [fmt(t)]
    if i + 1 < len(vs):
        nxt = vs[i + 1]
        forms.append(f">={fmt(t)} <{fmt(nxt)}")
        if i > 0:
            forms.append(f">{fmt(vs[i - 1])} <{fmt(nxt)}")
    else:
        forms.append(f">={fmt(t)}")
    if i > 0:
        forms.append(f">{fmt(vs[i - 1])} <={fmt(t)}")
    if not any(v > t and v[:2] == t[:2] for v in vs):
        forms.append("~" + fmt(t))
    if t[0] != 0:
        same = [v for v in vs if v > t and v[0] == t[0]]
    elif t[1] != 0:
        same = [v for v in vs if v > t and v[:2] == t[:2]]
    else:
        same = []
    if not same:
        forms.append("^" + fmt(t))
    return r.choice(forms)


def layered_names_versions(r, npk, nver):
    names = [f"pkg{i:03d}" for i in range(npk)]
    vers = {n: gen_versions(r, nver) for n in names}
    return names, vers


def big_consistent(seed, npk, nver, fan, nroot):
    """Large layered registry where every range admits the newest version of
    its target, so the newest-first search never backtracks; exercises
    parsing, range evaluation and reachability at scale."""
    r = random.Random(seed)
    names, vers = layered_names_versions(r, npk, nver)
    lines = []
    for i, n in enumerate(names):
        for v in vers[n]:
            cands = names[i + 1:]
            k = min(len(cands), r.randrange(0, fan + 1))
            deps = r.sample(cands, k)
            parts = [f"{d} {range_including(r, vers[d], vers[d][-1])}" for d in deps]
            lines.append(f"{n} {fmt(v)}:" + (" " + ", ".join(parts) if parts else ""))
    rootdeps = r.sample(names[:25], nroot)
    parts = [f"{d} {range_including(r, vers[d], vers[d][-1])}" for d in rootdeps]
    lines.append("root: " + ", ".join(parts))
    return "\n".join(lines) + "\n"


def big_pinned(seed, npk, nver, fan, npinned, nwobble, nroot):
    """Large layered registry whose root first pins some packages to old
    versions. Other packages' ranges on pinned packages admit the pinned
    version; "wobbler" packages have newer versions whose first dependency
    rejects a pinned version, so the search must step down through them."""
    r = random.Random(seed)
    names, vers = layered_names_versions(r, npk, nver)
    pinned = {}
    for n in r.sample(names, npinned):
        pinned[n] = r.choice(vers[n][:len(vers[n]) // 2])
    wobblers = {}
    for n in r.sample([n for n in names if n not in pinned], nwobble):
        nbad = r.randrange(1, len(vers[n]))
        wobblers[n] = nbad  # the nbad newest versions are unusable
    # target version each package ends up at
    target = {}
    for n in names:
        if n in pinned:
            target[n] = pinned[n]
        elif n in wobblers:
            target[n] = vers[n][-1 - wobblers[n]]
        else:
            target[n] = vers[n][-1]
    lines = []
    for i, n in enumerate(names):
        for vi, v in enumerate(vers[n]):
            cands = names[i + 1:]
            k = min(len(cands), r.randrange(1, fan + 1))
            deps = r.sample(cands, k)
            if n in pinned and v == pinned[n]:
                # The pinned version is resolved before the remaining pins
                # are chosen, so its subtree may only contain pinned packages
                # at exactly their pinned versions; anything else could pick
                # a not-yet-pinned package at a version the root later
                # rejects and the search would unwind the whole subtree.
                deps = [d for d in deps if d in pinned]
                parts = [f"{d} {range_only(r, vers[d], pinned[d])}" for d in deps]
                lines.append(f"{n} {fmt(v)}:" + (" " + ", ".join(parts) if parts else ""))
                continue
            parts = [f"{d} {range_including(r, vers[d], target[d])}" for d in deps]
            bad = n in wobblers and vi >= len(vers[n]) - wobblers[n]
            if bad:
                p = r.choice(list(pinned))
                pv = pinned[p]
                above = [w for w in vers[p] if w > pv]
                rej = r.choice([f">{fmt(pv)}", f">={fmt(above[0])}", "^" + fmt(above[-1]),
                                f">{fmt(pv)} <={fmt(above[-1])}"])
                # the requirements on one line must name distinct packages
                parts = [x for x in parts if not x.startswith(p + " ")]
                parts.insert(0, f"{p} {rej}")
            lines.append(f"{n} {fmt(v)}:" + (" " + ", ".join(parts) if parts else ""))
    rootdeps = [f"{p} {fmt(pinned[p])}" for p in sorted(pinned)]
    for d in r.sample(names[:25], nroot):
        rootdeps.append(f"{d} {range_including(r, vers[d], target[d])}")
    lines.append("root: " + ", ".join(rootdeps))
    return "\n".join(lines) + "\n"


def big_lockfile(seed, npk, nver, fan, nroot, conflict):
    """Large layered registry in which every range matches exactly one
    version, like a lockfile, so every choice point has a single candidate.
    With conflict=True the root's last requirement is a package `clash`
    whose two versions both demand the root's first package at a version
    other than the planted one: the whole tree is built first, then the
    conflict is found and the search must unwind every frame (each with no
    candidate left) before reporting unsatisfiable."""
    r = random.Random(seed)
    names, vers = layered_names_versions(r, npk, nver)
    planted = {n: r.choice(vers[n]) for n in names}
    lines = []
    for i, n in enumerate(names):
        for v in vers[n]:
            cands = names[i + 1:]
            k = min(len(cands), r.randrange(1, fan + 1)) if cands else 0
            deps = r.sample(cands, k)
            parts = [f"{d} {range_only(r, vers[d], planted[d])}" for d in deps]
            lines.append(f"{n} {fmt(v)}:" + (" " + ", ".join(parts) if parts else ""))
    rootdeps = r.sample(names[:25], nroot)
    parts = [f"{d} {range_only(r, vers[d], planted[d])}" for d in rootdeps]
    if conflict:
        first = rootdeps[0]
        others = [v for v in vers[first] if v != planted[first]]
        for k, o in enumerate(r.sample(others, 2)):
            lines.append(f"clash {2 - k}.0.0: {first} {range_only(r, vers[first], o)}")
        parts.append("clash *")
    lines.append("root: " + ", ".join(parts))
    return "\n".join(lines) + "\n"


def generated():
    cases = []
    cases.append(("deep_chain_3000", deep_chain(3000)))
    cases.append(("many_versions_250", many_versions(250, 7)))
    cases.append(("bt_stress_3x20", bt_stress(3, 20)))
    cases.append(("bt_stress_4x15", bt_stress(4, 15)))
    cases.append(("subtree_retry_8x30", subtree_retry(8, 30)))
    cases.append(("rand50_sat_a", random_registry(3, 50, 5, 4, 3)))
    cases.append(("rand50_unsat_a", random_registry(4, 50, 5, 4, 3)))
    cases.append(("rand60_sat_a", random_registry(108, 60, 6, 4, 3)))
    cases.append(("rand60_unsat_a", random_registry(115, 60, 6, 4, 3)))
    cases.append(("rand100_sat_a", random_registry(206, 100, 8, 5, 4)))
    cases.append(("rand100_unsat_a", random_registry(204, 100, 8, 5, 4)))
    cases.append(("rand100_unsat_heavy", random_registry(201, 100, 8, 5, 4)))
    cases.append(("rand50_unsat_heavy", random_registry(6, 50, 5, 4, 3)))
    cases.append(("big_lockfile_sat_500x20", big_lockfile(901, 500, 20, 12, 8, False)))
    cases.append(("big_lockfile_unsat_500x20", big_lockfile(902, 500, 20, 12, 8, True)))
    cases.append(("big_consistent_500x20", big_consistent(903, 500, 20, 30, 10)))
    cases.append(("big_pinned_500x20", big_pinned(904, 500, 20, 24, 30, 60, 10)))
    cases.append(("big_widefan_500x20", big_consistent(905, 500, 20, 40, 12)))
    return cases


def main():
    os.makedirs(TESTS, exist_ok=True)
    for f in os.listdir(TESTS):
        os.remove(os.path.join(TESTS, f))
    cases = HAND + generated()
    for idx, (name, text) in enumerate(cases, start=1):
        base = f"{idx:03d}_{name}"
        validate(text)
        with open(os.path.join(TESTS, base + ".in"), "w") as f:
            f.write(text)
        proc = subprocess.run([sys.executable, REF], input=text, capture_output=True, text=True, check=True)
        expected = oracle_in_big_stack(text)
        if proc.stdout != expected:
            print(f"ORACLE MISMATCH on {base}:\n--- reference\n{proc.stdout}--- oracle\n{expected}")
            sys.exit(1)
        with open(os.path.join(TESTS, base + ".out"), "w") as f:
            f.write(proc.stdout)
        summary = proc.stdout.strip().split("\n")[0] if proc.stdout.strip() else "(empty)"
        npkgs = proc.stdout.count("\n") if proc.stdout != "unsatisfiable\n" else 0
        print(f"{base}: {len(text)} bytes -> {summary}{' ...' if npkgs > 1 else ''} ({npkgs} packages)")
    print(f"{len(cases)} tests written")


if __name__ == "__main__":
    main()
