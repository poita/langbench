#!/usr/bin/env python3
"""Generates the datalog performance benchmark inputs (bench/NNN_name.in/.out).

Three deterministic (fixed-seed) programs, each within SPEC.md's limits
(<= 10,000 clauses, <= 6 arguments, <= 60 predicates, <= 8 body literals,
<= 3,000 lines per query, < 100 KB of output):

  001  graph analytics: semi-naive transitive closure of a large sparse random
       graph followed by several strata of negation over the closure.
  002  non-linear and mutually recursive rules: doubling-style closure
       (link :- link, link), alternating red/blue paths joined across two
       mutually recursive predicates, and same-generation on a wide tree.
  003  a realistic mixed workload: Andersen-style points-to analysis of a
       synthetic program with call-graph reachability, negation and
       comparisons.

Expected outputs come from reference/main.py unless --no-reference is given,
in which case the .out files are left untouched.

With --long the same three programs, on larger and denser relations, go to
../bench-long instead; their expected outputs also come from the reference.
The long sizes are capped by the reference's memory (it keeps every candidate
derivation of a join in memory): each needs at most about 4 GB.

Usage: python3 gen_bench.py [--no-reference] [--only N] [--long]
"""
import argparse
import os
import random
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REF = os.path.join(HERE, "..", "reference", "main.py")


def fact(pred, *args):
    return "%s(%s)." % (pred, ", ".join(str(a) for a in args))


def random_edges(rng, n_nodes, n_edges):
    edges = set()
    while len(edges) < n_edges:
        a, b = rng.randint(1, n_nodes), rng.randint(1, n_nodes)
        if a != b:
            edges.add((a, b))
    return sorted(edges)


# ---------------------------------------------------------------------------
# 001: closure of a large sparse graph + stratified negation over it
# ---------------------------------------------------------------------------

G1_NODES = 1200
G1_EDGES = 3100


def graph_analytics_program(G1_NODES=G1_NODES, G1_EDGES=G1_EDGES):
    rng = random.Random(20261011)
    edges = random_edges(rng, G1_NODES, G1_EDGES)
    rng.shuffle(edges)
    lines = ["%% graph analytics: %d nodes, %d edges" % (G1_NODES, G1_EDGES)]
    lines += [fact("node", i) for i in range(1, G1_NODES + 1)]
    lines += [fact("edge", a, b) for a, b in edges]
    lines += [
        "path(X, Y) :- edge(X, Y).",
        "path(X, Z) :- edge(X, Y), path(Y, Z).",
        "hasout(X) :- edge(X, _).",
        "hasin(X) :- edge(_, X).",
        "sink(X) :- node(X), not hasout(X).",
        "source(X) :- node(X), not hasin(X).",
        "cyclic(X) :- path(X, X).",
        "acyclic(X) :- node(X), not cyclic(X).",
        "mutual(X, Y) :- path(X, Y), path(Y, X), X < Y.",
        "unreachable(X) :- node(X), not path(1, X), X != 1.",
        "misses(X) :- node(X), node(Y), not path(X, Y), X != Y.",
        "sees_all(X) :- node(X), not misses(X).",
        "feeds_sink(X, S) :- path(X, S), sink(S).",
        "lonely(X) :- node(X), not feeds_any(X).",
        "feeds_any(X) :- feeds_sink(X, _).",
        "?- path(2, X).",
        "?- path(X, 7).",
        "?- path(%d, %d)." % (G1_NODES // 2, G1_NODES // 2 + 1),
        "?- sink(X).",
        "?- source(X).",
        "?- acyclic(X).",
        "?- mutual(3, X).",
        "?- unreachable(X).",
        "?- sees_all(X).",
        "?- feeds_sink(5, S).",
        "?- lonely(X).",
    ]
    return "\n".join(lines) + "\n"


# ---------------------------------------------------------------------------
# 002: non-linear and mutual recursion
# ---------------------------------------------------------------------------

G2_NL_NODES = 230
G2_NL_EDGES = 650
G2_RB_NODES = 380
G2_RB_EDGES = 930
G2_TREE = 3000


def recursion_program(G2_NL_NODES=G2_NL_NODES, G2_NL_EDGES=G2_NL_EDGES,
                      G2_RB_NODES=G2_RB_NODES, G2_RB_EDGES=G2_RB_EDGES, G2_TREE=G2_TREE):
    rng = random.Random(77)
    lines = ["% non-linear closure, mutual recursion, same generation"]
    # Non-linear closure over a random graph.
    for a, b in random_edges(rng, G2_NL_NODES, G2_NL_EDGES):
        lines.append(fact("e", a, b))
    lines += [
        "link(X, Y) :- e(X, Y).",
        "link(X, Z) :- link(X, Y), link(Y, Z).",
        "twohop(X, Z) :- link(X, Y), link(Y, Z), not e(X, Z).",
    ]
    # Alternating red/blue paths: two mutually recursive predicates, and a
    # non-linear rule joining both of them in one body.
    for a, b in random_edges(rng, G2_RB_NODES, G2_RB_EDGES):
        lines.append(fact("red" if rng.random() < 0.5 else "blue", "n%d" % a, "n%d" % b))
    lines += [
        "rb(X, Y) :- red(X, Y).",
        "br(X, Y) :- blue(X, Y).",
        "rb(X, Z) :- red(X, Y), br(Y, Z).",
        "br(X, Z) :- blue(X, Y), rb(Y, Z).",
        "alt(X, Z) :- rb(X, Y), br(Y, Z).",
        "alt(X, Z) :- alt(X, Y), alt(Y, Z).",
    ]
    # Same generation over a wide tree.
    for child in range(2, G2_TREE + 1):
        parent = rng.randint(max(1, child // 3), child - 1)
        lines.append(fact("par", "t%d" % parent, "t%d" % child))
    lines += [
        "sg(X, X) :- par(_, X).",
        "sg(X, Y) :- par(XP, X), sg(XP, YP), par(YP, Y).",
        "cousin(X, Y) :- sg(X, Y), par(P, X), not par(P, Y).",
        "?- link(1, X).",
        "?- link(X, X).",
        "?- twohop(2, X).",
        "?- rb(n4, X).",
        "?- br(X, n5).",
        "?- alt(n5, X).",
        "?- alt(X, X).",
        "?- sg(t%d, X)." % (G2_TREE // 2),
        "?- cousin(t%d, X)." % (G2_TREE - 1),
    ]
    return "\n".join(lines) + "\n"


# ---------------------------------------------------------------------------
# 003: Andersen-style points-to analysis with a call graph
# ---------------------------------------------------------------------------

P_FUNCS = 300
P_VARS_PER_FUNC = 8
P_OBJS = 900
P_FIELDS = 6


def points_to_program(P_FUNCS=P_FUNCS):
    rng = random.Random(4242)
    lines = ["% points-to analysis of a synthetic program"]
    nvars = P_FUNCS * P_VARS_PER_FUNC

    def var(f, i):
        return "v%d_%d" % (f, i)

    def any_var_in(f):
        return var(f, rng.randrange(P_VARS_PER_FUNC))

    def nearby_func(f):
        return max(0, min(P_FUNCS - 1, f + rng.randint(-15, 15)))

    obj = 0
    for f in range(P_FUNCS):
        lines.append(fact("func", "f%d" % f))
        for i in range(P_VARS_PER_FUNC):
            lines.append(fact("var_in", var(f, i), "f%d" % f))
        # allocation sites
        for _ in range(3):
            lines.append(fact("new", any_var_in(f), "o%d" % obj, obj % 50))
            obj += 1
        # local copies
        for _ in range(4):
            lines.append(fact("assign", any_var_in(f), any_var_in(f)))
        # field stores and loads
        for _ in range(2):
            lines.append(fact("store", any_var_in(f), "fld%d" % rng.randrange(P_FIELDS), any_var_in(f)))
        for _ in range(2):
            lines.append(fact("load", any_var_in(f), any_var_in(f), "fld%d" % rng.randrange(P_FIELDS)))
        # calls: argument and return-value flow between nearby functions
        for _ in range(2):
            g = nearby_func(f)
            lines.append(fact("call", "f%d" % f, "f%d" % g))
            lines.append(fact("actual", "f%d" % f, "f%d" % g, any_var_in(f), var(g, 0)))
            lines.append(fact("retval", "f%d" % g, var(g, P_VARS_PER_FUNC - 1)))
            lines.append(fact("callret", "f%d" % f, "f%d" % g, any_var_in(f)))
    lines.append(fact("entry", "f0"))
    lines.append(fact("entry", "f%d" % (P_FUNCS // 2)))
    lines += [
        "reach(F) :- entry(F).",
        "reach(G) :- reach(F), call(F, G).",
        "dead(F) :- func(F), not reach(F).",
        "live_var(V) :- var_in(V, F), reach(F).",
        "assign(V, W) :- actual(_, _, W, V).",
        "assign(V, W) :- callret(F, G, V), retval(G, W).",
        "pt(V, O) :- new(V, O, _), live_var(V).",
        "pt(V, O) :- assign(V, W), pt(W, O).",
        "hpt(O1, F, O2) :- store(V, F, W), pt(V, O1), pt(W, O2).",
        "pt(V, O2) :- load(V, W, F), pt(W, O1), hpt(O1, F, O2).",
        "may_alias(X, Y) :- pt(X, O), pt(Y, O), X < Y.",
        "hot_obj(O) :- new(_, O, Site), Site >= 40.",
        "hot_ref(V) :- pt(V, O), hot_obj(O).",
        "pure_var(V) :- live_var(V), not hot_ref(V).",
        "callee_sees(F, O) :- call(F, G), var_in(V, G), pt(V, O).",
        "?- dead(X).",
        "?- pt(v0_0, O).",
        "?- pt(%s, O)." % var(P_FUNCS // 2, 3),
        "?- hpt(o7, F, O).",
        "?- may_alias(v10_1, Y).",
        "?- hot_ref(%s)." % var(10, 1),
        "?- callee_sees(f%d, O)." % (P_FUNCS // 3),
        "?- pure_var(X).",
    ]
    return "\n".join(lines) + "\n"


BENCHES = [
    ("001_graph_closure_negation", graph_analytics_program),
    ("002_nonlinear_mutual_recursion", recursion_program),
    ("003_points_to_analysis", points_to_program),
]

# Long tier (--long, written to ../bench-long): the same three programs on
# larger and denser relations, under the raised clause limit in SPEC.md. Sizes
# are the largest tried whose reference run stays under about 4 GB peak memory.
LONG_MAX_CLAUSES = 50000
LONG_BENCHES = [
    ("001_graph_closure_negation", lambda: graph_analytics_program(1800, 23000)),
    ("002_nonlinear_mutual_recursion",
     lambda: recursion_program(290, 820, 480, 1175, 3000)),
    ("003_points_to_analysis", lambda: points_to_program(1500)),
]


def check_limits(name, text, max_clauses=10000):
    clauses = text.count(".\n")
    assert clauses <= max_clauses, (name, clauses)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--no-reference", action="store_true")
    ap.add_argument("--only", default="")
    ap.add_argument("--long", action="store_true")
    args = ap.parse_args()
    out_dir, benches, max_clauses = HERE, BENCHES, 10000
    if args.long:
        out_dir, benches, max_clauses = os.path.join(HERE, "..", "bench-long"), LONG_BENCHES, LONG_MAX_CLAUSES
        os.makedirs(out_dir, exist_ok=True)
    for name, gen in benches:
        if args.only and not name.startswith(args.only):
            continue
        text = gen()
        check_limits(name, text, max_clauses)
        with open(os.path.join(out_dir, name + ".in"), "w") as f:
            f.write(text)
        print("%-36s in=%8d bytes, %d clauses" % (name, len(text), text.count(".\n")), flush=True)
        if args.no_reference:
            continue
        proc = subprocess.run([sys.executable, REF], input=text.encode(), capture_output=True)
        assert proc.returncode == 0, proc.stderr.decode()
        out = proc.stdout.decode()
        with open(os.path.join(out_dir, name + ".out"), "w") as f:
            f.write(out)
        counts = [int(l[3:]) for l in out.split("\n") if l.startswith("-- ")]
        print("    out=%d bytes, per-query counts %s" % (len(out), counts), flush=True)


if __name__ == "__main__":
    main()
