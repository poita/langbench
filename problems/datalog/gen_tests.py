#!/usr/bin/env python3
"""Generates tests/*.in and tests/*.out for the `datalog` problem.

Hand-written edge cases are embedded as literals; larger programs come from
seeded generators. Expected outputs are produced by reference/main.py and
every one of them is cross-checked against an independent oracle:

- `naive`: a separate, deliberately simple evaluator in this file (regex
  tokenizer, iterative stratum numbering, naive fixpoint that re-derives
  every rule from the full relations each round, positives-first literal
  order). It shares no code with the reference.
- a structural oracle for the 2000-node chain closure, whose ~2M tuples make
  naive re-derivation far too slow: reachability there is answered by
  breadth-first search over the edge list.

The script aborts if the reference and the oracle disagree on any test.
"""
import os
import random
import re
import subprocess
import sys
from collections import deque

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.join(HERE, "tests")
REF = os.path.join(HERE, "reference", "main.py")

cases = []


def add(name, text, oracle="naive"):
    """oracle: 'naive', a callable returning the expected output text, or None."""
    cases.append((name, text, oracle))


# ---------------------------------------------------------------------------
# Hand-written cases
# ---------------------------------------------------------------------------

add("single_fact", "edge(1, 2).\n?- edge(1, 2).\n")
add("empty_result", "edge(1, 2).\n?- edge(2, X).\n?- edge(1, 1).\n")
add("no_queries", "edge(1, 2).\np(X) :- edge(X, Y).\n")
add("empty_program", "")
add("comments_only", "% only comments here\n%?- p(X).\n   \n\t% p(1).\n")
add("undefined_predicate", "?- nothing(X, Y).\nfoo(1).\n?- bar(1).\n?- foo(X).\n")
add("sort_order_mixed", """v(b, 1). v(a, 2). v(10, x). v(2, y). v(-3, z). v(a_b, 0). v(ab, 0). v(a, -1).
v(1000000000, q). v(-1000000000, q). v(0, 0). v(a, 10). v(a, 9). v(a, b). v(a, a).
?- v(X, Y).
?- v(a, X).
?- v(X, 0).
""")
add("query_patterns", """edge(1, 2). edge(2, 2). edge(3, 1). edge(1, 1). edge(x, x). edge(x, 2).
?- edge(X, X).
?- edge(_, 2).
?- edge(X, _).
?- edge(_, _).
?- edge(1, 1).
?- edge(2, 1).
?- edge(x, Y).
""")
add("transitive_closure", """edge(1, 2). edge(2, 3). edge(3, 1). edge(3, 4).
path(X, Y) :- edge(X, Y).
path(X, Z) :- edge(X, Y), path(Y, Z).
?- path(1, X).
?- path(4, X).
?- path(X, X).
?- path(X, Y).
""")
add("constants_in_head", """edge(1, 2). edge(2, 3).
label(X, red) :- edge(X, _).
label(0, none) :- edge(_, _).
label(9, blue) :- edge(5, 6).
ok(1, 2) :- edge(1, 2).
colour(green, X, X, 7) :- edge(_, X).
?- label(X, Y).
?- ok(X, Y).
?- colour(A, B, C, D).
""")
add("repeated_variables", """edge(1, 2). edge(2, 3). edge(3, 1). edge(2, 2). edge(4, 1). edge(5, 1). edge(a, a).
node(1). node(2). node(a).
loop(X) :- edge(X, X).
tri(X) :- edge(X, Y), edge(Y, Z), edge(Z, X).
twin(X, Y) :- edge(X, Z), edge(Y, Z), X != Y.
pair(X, X) :- node(X).
both(X) :- edge(X, X), node(X).
?- loop(X).
?- tri(X).
?- twin(X, Y).
?- pair(X, Y).
?- both(X).
""")
add("comparisons", """n(1). n(2). n(3). n(-1). n(a). n(b). n(0).
lt(X, Y) :- n(X), n(Y), X < Y.
le(X, Y) :- n(X), n(Y), X <= Y.
gt(X, Y) :- n(X), n(Y), X > Y.
ge(X, Y) :- n(X), n(Y), X >= Y.
eq(X, Y) :- n(X), n(Y), X = Y.
ne(X, Y) :- n(X), n(Y), X != Y.
c1(X) :- n(X), X < a.
c2(X) :- n(X), a <= X.
c3(X) :- n(X), X = 2.
c4(X) :- n(X), X != b, X != 2.
c5(X) :- n(X), 1 < 2.
c6(X) :- n(X), 2 < 1.
c7(X) :- n(X), X >= -1, X <= 1.
?- lt(X, Y).
?- le(X, Y).
?- gt(X, Y).
?- ge(X, Y).
?- eq(X, Y).
?- ne(X, Y).
?- c1(X).
?- c2(X).
?- c3(X).
?- c4(X).
?- c5(X).
?- c6(X).
?- c7(X).
""")
add("ancestors", """parent(alice, bob). parent(alice, carol). parent(bob, dave). parent(carol, erin).
parent(dave, frank). parent(erin, frank). parent(zed, alice).
ancestor(X, Y) :- parent(X, Y).
ancestor(X, Z) :- parent(X, Y), ancestor(Y, Z).
sibling(X, Y) :- parent(P, X), parent(P, Y), X != Y.
cousin(X, Y) :- parent(A, X), parent(B, Y), sibling(A, B).
?- ancestor(X, frank).
?- ancestor(zed, X).
?- ancestor(frank, X).
?- sibling(X, Y).
?- cousin(X, Y).
?- ancestor(X, X).
""")
add("same_generation", """par(a, b). par(a, c). par(b, d). par(b, e). par(c, f). par(d, g). par(f, h).
sg(X, X) :- par(_, X).
sg(X, X) :- par(X, _).
sg(X, Y) :- par(XP, X), sg(XP, YP), par(YP, Y).
?- sg(d, X).
?- sg(g, X).
?- sg(X, Y).
""")
add("negation_unreachable", """node(1). node(2). node(3). node(4). node(5). node(6).
edge(1, 2). edge(2, 3). edge(3, 1). edge(4, 5). edge(5, 4). edge(6, 6).
reach(X) :- edge(1, X).
reach(Y) :- reach(X), edge(X, Y).
unreachable(X) :- node(X), not reach(X).
?- reach(X).
?- unreachable(X).
""")
add("negation_complement", """all(1). all(2). all(3). all(4). all(a). all(b).
sub(2). sub(a). sub(zzz).
rest(X) :- all(X), not sub(X).
none(X) :- all(X), not all(X).
missing(X) :- sub(X), not all(X).
gone(X, Y) :- all(X), all(Y), not sub(X), not sub(Y), X < Y.
?- rest(X).
?- none(X).
?- missing(X).
?- gone(X, Y).
""")
add("multi_stratum", """base(1). base(2). base(3). base(4). base(5). base(6).
s1(X) :- base(X), X > 2.
s2(X) :- base(X), not s1(X).
s3(X) :- base(X), not s2(X), X != 4.
s4(X) :- base(X), not s3(X).
s4(X) :- s2(X), not s3(X).
top(X, Y) :- s4(X), s1(Y), not s3(Y), X < Y.
?- s1(X).
?- s2(X).
?- s3(X).
?- s4(X).
?- top(X, Y).
""")
add("mutual_recursion", """zero(0).
succ(0, 1). succ(1, 2). succ(2, 3). succ(3, 4). succ(4, 5). succ(5, 6). succ(6, 7).
even(X) :- zero(X).
even(X) :- succ(Y, X), odd(Y).
odd(X) :- succ(Y, X), even(Y).
?- even(X).
?- odd(X).
?- even(7).
""")
add("negation_before_positive", """r(1). r(2). r(3). q(2).
p(X) :- not q(X), r(X).
p2(X) :- X > 1, r(X).
p3(X) :- X != Y, not q(Y), r(Y), r(X).
p4(Y, X) :- not q(X), r(Y), Y < X, r(X).
?- p(X).
?- p2(X).
?- p3(X).
?- p4(X, Y).
""")
add("duplicates", """e(1, 2). e(1, 2). e(2, 3).
e(2, 3).
t(X, Y) :- e(X, Y).
t(X, Y) :- e(X, Y).
t(X, Z) :- t(X, Y), e(Y, Z).
t(X, Z) :- e(X, Y), t(Y, Z).
t(1, 3).
?- t(X, Y).
?- e(X, Y).
?- e(1, 2).
""")
add("comments_and_whitespace", "% a comment line\nedge(1,2).edge(2,\n\t3). % trailing comment\n\r\n  path(X,Y):-edge(X,Y).\npath(X,\nZ) :-\n  edge(X,Y),\n  path(Y,Z).   %%% more\n?-path(1,X).\n?- path(X, 3) .\n%?- path(9, 9).\n")
add("queries_before_facts", """?- path(X, Y).
?- edge(1, X).
path(X, Y) :- edge(X, Y).
?- path(Y, 2).
edge(1, 2).
path(X, Z) :- path(X, Y), edge(Y, Z).
edge(2, 3).
?- path(X, Y).
""")
add("facts_and_rules_same_predicate", """edge(1, 2). edge(2, 3).
path(9, 9). path(3, 4).
path(X, Y) :- edge(X, Y).
path(X, Z) :- path(X, Y), edge(Y, Z).
path(X, Z) :- edge(X, Y), path(Y, Z).
?- path(X, Y).
""")
add("negative_integers", """v(-5). v(-1). v(0). v(1). v(-1000000000). v(1000000000). v(neg).
neg(X) :- v(X), X < 0.
nonneg(X) :- v(X), X >= 0.
between(X) :- v(X), -5 < X, X < 1.
pair(X, Y) :- v(X), v(Y), X < Y, Y < -1.
?- neg(X).
?- nonneg(X).
?- between(X).
?- pair(X, Y).
?- v(-1).
""")
add("identifier_order", """w(a). w(a_b). w(ab). w(a0). w(a_). w(aa). w(b). w(a9z). w(a_9). w(abc). w(z). w(zz).
lt(X, Y) :- w(X), w(Y), X < Y.
first(X) :- w(X), not later(X).
later(X) :- w(X), w(Y), Y < X.
?- w(X).
?- lt(a, Y).
?- lt(X, aa).
?- first(X).
""")
add("negation_over_undefined", """r(1). r(2).
p(X) :- r(X), not never(X).
q(X) :- r(X), not never(X, X).
?- p(X).
?- q(X).
?- never(X).
""")
add("positive_and_negated_same_predicate", """q(1). q(2). q(3).
p(X) :- q(X), not q(X).
s(X) :- q(X), not t(X).
t(X) :- q(X), X > 2.
u(X, Y) :- q(X), q(Y), not q(Z), q(Z), X < Y.
?- p(X).
?- s(X).
?- u(X, Y).
""")
add("recursion_above_negation", """node(1). node(2). node(3). node(4). node(5). node(6). node(7).
edge(1, 2). edge(2, 3). edge(4, 5). edge(5, 6). edge(6, 4). edge(6, 7). edge(7, 3).
reach(X) :- edge(1, X).
reach(Y) :- reach(X), edge(X, Y).
unreachable(X) :- node(X), not reach(X).
chain(X, Y) :- unreachable(X), unreachable(Y), edge(X, Y).
chain(X, Z) :- chain(X, Y), chain(Y, Z).
lonely(X) :- unreachable(X), not chain(X, X).
?- reach(X).
?- unreachable(X).
?- chain(X, Y).
?- lonely(X).
""")
add("closure_late_base_tuples", """% Transitive closure whose base tuples arrive in different fixpoint rounds:
% the `late` links only join `link` once link(1, 2) exists, so the closure
% rule must combine tuples derived earlier with tuples derived later, in
% either argument position.
edge(1, 2).
late(2, 3). late(3, 4).
link(X, Y) :- edge(X, Y).
link(X, Y) :- unlocked(X, Y).
unlocked(X, Y) :- late(X, Y), link(1, 2).
link(X, Z) :- link(X, Y), link(Y, Z).
?- link(X, Y).
?- unlocked(X, Y).
""")
add("nonlinear_mutual_recursion", """% Two mutually recursive predicates joined in one body: ab = a . b, and both
% a and b absorb ab, so new b tuples must be joined with old a tuples.
stepa(0, 1). stepa(1, 2). stepa(5, 6).
stepb(2, 3). stepb(3, 4). stepb(4, 5). stepb(6, 7).
a(X, Y) :- stepa(X, Y).
b(X, Y) :- stepb(X, Y).
ab(X, Z) :- a(X, Y), b(Y, Z).
a(X, Y) :- ab(X, Y).
b(X, Y) :- ab(X, Y).
?- ab(X, Y).
?- ab(0, X).
?- a(X, Y).
?- b(X, Y).
""")
add("error_unsafe_head_variable", "q(1).\np(X) :- q(Y).\n?- p(X).\n")
add("error_unsafe_negation_variable", "q(1). r(1).\np(X) :- q(X), not r(Y).\n?- p(X).\n")
add("error_unsafe_comparison_variable", "q(1).\np(X) :- q(X), X < Y.\n?- p(X).\n")
add("error_unsafe_equality_binding", "q(1). q(2).\np(Y) :- q(X), X = Y.\n?- p(X).\n")
add("error_unsafe_equality_unused", "q(1). q(2).\np(X) :- q(X), Y = 5.\n?- p(X).\n")
add("error_unsafe_negation_then_equality", "q(1). q(2).\np(X) :- q(X), not r(Y), Y = X.\n?- p(X).\n")
add("error_fact_with_variable", "p(1).\np(X).\n?- p(X).\n")
add("error_fact_with_anonymous", "p(1).\np(_).\n?- p(X).\n")
add("error_anonymous_in_head", "q(1).\np(_) :- q(1).\n?- p(X).\n")
add("error_anonymous_in_negation", "q(1). r(1).\np(X) :- q(X), not r(_).\n?- p(X).\n")
add("error_anonymous_in_comparison", "q(1).\np(X) :- q(X), _ < X.\n?- p(X).\n")
add("error_unstratifiable_self", "edge(1, 2). edge(2, 3).\nwin(X) :- edge(X, Y), not win(Y).\n?- win(X).\n")
add("error_unstratifiable_mutual", "s(1). s(2).\na(X) :- s(X), b(X).\nb(X) :- s(X), not a(X).\n?- a(X).\n?- b(X).\n")
add("error_unstratifiable_long_cycle", """s(1).
a(X) :- s(X), not c(X).
b(X) :- a(X).
c(X) :- b(X), s(X).
d(X) :- c(X), not a(X).
?- d(X).
""")
add("error_after_valid_queries", """edge(1, 2).
?- edge(1, X).
?- edge(X, Y).
path(X, Y) :- edge(X, Y).
bad(X) :- edge(X, Y), not bad(Y).
?- path(X, Y).
""")
add("error_unsafe_among_many", """edge(1, 2). edge(2, 3). edge(3, 4).
path(X, Y) :- edge(X, Y).
path(X, Z) :- edge(X, Y), path(Y, Z).
?- path(X, Y).
count(X, N) :- path(X, _).
?- count(X, N).
""")
add("error_comparison_only_body", "p(X) :- X < 3.\n?- p(X).\n")
add("error_no_queries_unsafe", "q(1).\np(X) :- q(Y).\n")
add("error_no_queries_unstratifiable", "q(1).\np(X) :- q(X), not p(X).\n")
add("stratifiable_negation_chain", """r(1). r(2). r(3). s(1).
p(X) :- r(X), not q(X).
q(X) :- r(X), not s(X).
t(X) :- p(X), not u(X).
u(X) :- r(X), not p(X), not q(X).
?- p(X).
?- q(X).
?- t(X).
?- u(X).
""")
add("comparison_between_constants", """q(2).
p(1) :- q(2), 1 < 2.
p(2) :- q(2), 3 < 2.
p(3) :- q(2), a > 5.
p(4) :- q(2), a = a.
p(5) :- q(2), 5 = a.
p(6) :- q(2), 5 != a.
p(7) :- q(2), -3 <= -3.
?- p(X).
""")
add("negation_with_constants_only", """q(1). q(2). r(2).
p(X) :- q(X), not r(1).
p2(X) :- q(X), not r(2).
p3(X) :- q(X), not r(X, 5).
?- p(X).
?- p2(X).
?- p3(X).
""")
add("naming", """edge(edge, path). edge(path, not_a_keyword). edge(notx, edge). notx(1). notx(2).
path(Long_Var1, Long_Var1) :- edge(Long_Var1, _).
path(Long_Var1, Another_var_2) :- edge(Long_Var1, Another_var_2).
path(X, Z) :- path(X, Y), edge(Y, Z).
np(X) :- notx(X), not notx(2).
np2(X) :- notx(X), not np(X).
?- path(edge, X).
?- path(X, X).
?- np(X).
?- np2(X).
?- notx(X).
""")
add("wide_predicates", """t(1, 2, 3, 4, 5, 6). t(1, 2, 3, 4, 5, 7). t(0, 2, 3, 4, 5, 6). t(1, 1, 1, 1, 1, 1). t(a, b, c, d, e, f).
u(A, B, C, D, E, F) :- t(A, B, C, D, E, F), A = 1.
v(F, E, D, C, B, A) :- t(A, B, C, D, E, F).
w(X, Y) :- t(X, _, _, _, _, Y), t(Y, _, _, _, _, _).
?- t(1, _, _, _, _, X).
?- u(A, B, C, D, E, F).
?- v(A, B, C, D, E, F).
?- w(X, Y).
?- t(_, _, _, _, _, _).
?- t(X, X, X, X, X, X).
""")


# ---------------------------------------------------------------------------
# Generators
# ---------------------------------------------------------------------------

def fmt_const(c):
    return str(c)


def fact(pred, *args):
    return "%s(%s)." % (pred, ", ".join(fmt_const(a) for a in args))


def gen_random_program(seed, n_strata=3, n_facts=18, n_base=3):
    """Random safe, stratifiable program: negation only reaches strictly lower
    strata by construction; positive atoms may recurse within a stratum."""
    rng = random.Random(seed)
    consts = [-1, 0, 1, 2, 3, "a", "b", "c"]
    var_pool = ["X", "Y", "Z", "W"]
    preds = []
    lines = ["%% random program seed %d" % seed]
    for i in range(n_base):
        arity = rng.randint(1, 3)
        preds.append(("b%d" % i, arity, 0))
        for _ in range(n_facts):
            lines.append(fact("b%d" % i, *[rng.choice(consts) for _ in range(arity)]))
    for s in range(1, n_strata + 1):
        for k in range(2):
            preds.append(("d%d%d" % (s, k), rng.randint(1, 3), s))
    for name, arity, s in preds:
        if s == 0:
            continue
        for _ in range(rng.randint(2, 3)):
            body = []
            pos_vars = set()
            nb = rng.randint(1, 3)
            for _ in range(nb):
                cands = [p for p in preds if p[2] <= s and (p[2] < s or rng.random() < 0.5)]
                if not cands:
                    cands = [p for p in preds if p[2] < s]
                bp = rng.choice(cands)
                args = []
                for _ in range(bp[1]):
                    r = rng.random()
                    if r < 0.1:
                        args.append(fmt_const(rng.choice(consts)))
                    elif r < 0.18:
                        args.append("_")
                    else:
                        v = rng.choice(var_pool)
                        args.append(v)
                        pos_vars.add(v)
                body.append("%s(%s)" % (bp[0], ", ".join(args)))
            lower = [p for p in preds if p[2] < s]
            pv = sorted(pos_vars)
            if pv and lower and rng.random() < 0.4:
                np_ = rng.choice(lower)
                args = [rng.choice(pv) if rng.random() < 0.8 else fmt_const(rng.choice(consts)) for _ in range(np_[1])]
                body.append("not %s(%s)" % (np_[0], ", ".join(args)))
            if pv and rng.random() < 0.5:
                op = rng.choice(["<", "<=", ">", ">=", "=", "!="])
                a = rng.choice(pv)
                others = [v for v in pv if v != a]
                b = rng.choice(others) if others and rng.random() < 0.6 else fmt_const(rng.choice(consts))
                body.append("%s %s %s" % (a, op, b))
            if rng.random() < 0.3:
                rng.shuffle(body)
            head_args = []
            for _ in range(arity):
                if pv and rng.random() < 0.85:
                    head_args.append(rng.choice(pv))
                else:
                    head_args.append(fmt_const(rng.choice(consts)))
            lines.append("%s(%s) :- %s." % (name, ", ".join(head_args), ", ".join(body)))
    for name, arity, s in preds:
        if s == 0 and rng.random() < 0.5:
            continue
        lines.append("?- %s(%s)." % (name, ", ".join(var_pool[:arity])))
        if rng.random() < 0.5:
            args = []
            for i in range(arity):
                r = rng.random()
                if r < 0.4:
                    args.append(fmt_const(rng.choice(consts)))
                elif r < 0.6:
                    args.append("_")
                else:
                    args.append("X")
            lines.append("?- %s(%s)." % (name, ", ".join(args)))
    return "\n".join(lines) + "\n"


for seed in range(1, 9):
    add("gen_random_program_%d" % seed, gen_random_program(seed))


def chain_edges(n):
    return [(i, i + 1) for i in range(1, n)]


def random_edges(rng, n_nodes, n_edges):
    edges = set()
    while len(edges) < n_edges:
        a, b = rng.randint(1, n_nodes), rng.randint(1, n_nodes)
        edges.add((a, b))
    return sorted(edges)


def closure_program(edges, extra):
    lines = [fact("edge", a, b) for a, b in edges]
    lines += ["path(X, Y) :- edge(X, Y).", "path(X, Z) :- edge(X, Y), path(Y, Z)."]
    lines += extra
    return "\n".join(lines) + "\n"


add("gen_chain_300_closure", closure_program(chain_edges(300), [
    "?- path(1, X).", "?- path(X, 300).", "?- path(150, 151).", "?- path(151, 150).", "?- path(300, X).",
    "?- path(X, 1).", "?- path(X, X).",
]))

rng = random.Random(100)
small_graph = random_edges(rng, 60, 150)
add("gen_random_graph_60_full_closure", closure_program(small_graph, [
    "?- path(X, Y).", "?- path(1, X).", "?- path(X, X).",
]))


def same_generation_program(seed, n_nodes):
    rng = random.Random(seed)
    lines = []
    for child in range(2, n_nodes + 1):
        parent = rng.randint(max(1, child - 12), child - 1)
        lines.append(fact("par", parent, child))
    lines += [
        "sg(X, X) :- par(_, X).",
        "sg(X, X) :- par(X, _).",
        "sg(X, Y) :- par(XP, X), sg(XP, YP), par(YP, Y).",
        "?- sg(1, X).",
        "?- sg(%d, X)." % n_nodes,
        "?- sg(%d, X)." % (n_nodes // 2),
        "?- sg(X, 7).",
        "count(X) :- sg(X, Y), X < Y.",
        "?- count(X).",
        "alone(X) :- par(_, X), not count(X).",
        "?- alone(X).",
    ]
    return "\n".join(lines) + "\n"


add("gen_same_generation_tree_2000", same_generation_program(7, 2000))


def even_odd_program(n):
    lines = ["zero(0)."]
    lines += [fact("succ", i, i + 1) for i in range(n)]
    lines += [
        "even(X) :- zero(X).",
        "even(X) :- succ(Y, X), odd(Y).",
        "odd(X) :- succ(Y, X), even(Y).",
        "?- even(%d)." % n,
        "?- odd(%d)." % n,
        "?- odd(%d)." % (n - 1),
        "neither(X) :- succ(X, _), not even(X), not odd(X).",
        "?- neither(X).",
        "?- even(X).",
    ]
    return "\n".join(lines) + "\n"


add("gen_even_odd_chain_2000", even_odd_program(2000))

rng = random.Random(500)
big_graph = random_edges(rng, 500, 3000)
add("gen_random_graph_500_3000_closure_negation", closure_program(big_graph, [
    fact("node", i) for i in range(1, 501)
] + [
    "?- path(1, X).",
    "?- path(X, 1).",
    "?- path(250, 251).",
    "unreachable(X) :- node(X), not path(1, X).",
    "?- unreachable(X).",
    "dead_end(X) :- node(X), not hasout(X).",
    "hasout(X) :- edge(X, _).",
    "?- dead_end(X).",
    "source(X) :- node(X), not hasin(X).",
    "hasin(X) :- edge(_, X).",
    "?- source(X).",
    "cyclic(X) :- path(X, X).",
    "acyclic(X) :- node(X), not cyclic(X).",
    "?- acyclic(X).",
    "sees_all(X) :- node(X), not misses(X).",
    "misses(X) :- node(X), node(Y), not path(X, Y), X != Y.",
    "?- sees_all(X).",
]))


def ages_program(seed, n):
    rng = random.Random(seed)
    lines = [fact("age", "p%d" % i, rng.randint(1, 90)) for i in range(n)]
    lines += [
        "older(X, Y) :- age(X, A), age(Y, B), A > B.",
        "same(X, Y) :- age(X, A), age(Y, A), X != Y.",
        "oldest(X) :- age(X, _), not beaten(X).",
        "beaten(X) :- older(_, X).",
        "youngest(X) :- age(X, _), not beats(X).",
        "beats(X) :- older(X, _).",
        "adult(X) :- age(X, A), A >= 18.",
        "minor(X) :- age(X, _), not adult(X).",
        "?- oldest(X).",
        "?- youngest(X).",
        "?- minor(X).",
        "?- same(p1, X).",
        "?- older(p2, X).",
        "?- older(X, p3).",
    ]
    return "\n".join(lines) + "\n"


add("gen_ages_comparisons_500", ages_program(9, 500))


def layered_program(seed, n_nodes, n_edges):
    """Several strata of negation stacked on a random graph."""
    rng = random.Random(seed)
    edges = random_edges(rng, n_nodes, n_edges)
    lines = [fact("node", i) for i in range(1, n_nodes + 1)]
    lines += [fact("edge", a, b) for a, b in edges]
    lines += [
        "reach(X) :- edge(1, X).",
        "reach(Y) :- reach(X), edge(X, Y).",
        "unreach(X) :- node(X), not reach(X).",
        "ue(X, Y) :- edge(X, Y), unreach(X), unreach(Y).",
        "upath(X, Y) :- ue(X, Y).",
        "upath(X, Z) :- upath(X, Y), ue(Y, Z).",
        "uroot(X) :- unreach(X), not uinner(X).",
        "uinner(X) :- upath(_, X).",
        "far(X) :- uroot(X), not near(X).",
        "near(X) :- uroot(X), edge(X, Y), reach(Y).",
        "near(X) :- uroot(X), edge(Y, X), reach(Y).",
        "?- reach(X).",
        "?- unreach(X).",
        "?- upath(X, X).",
        "?- uroot(X).",
        "?- far(X).",
        "?- near(X).",
    ]
    return "\n".join(lines) + "\n"


add("gen_layered_negation_400", layered_program(11, 400, 800))

add("gen_large_error_unstratifiable", closure_program(big_graph, [
    "?- path(1, X).",
    "win(X) :- edge(X, Y), not win(Y).",
    "?- win(X).",
]))

add("gen_large_error_unsafe", closure_program(big_graph, [
    "?- path(1, X).",
    "far(X, Y) :- path(X, Z), not path(Z, Y).",
    "?- far(1, X).",
]))


def chain_expected(n):
    """Expected output for the chain test, from breadth-first search."""
    edges = chain_edges(n)
    fwd, rev = {}, {}
    for a, b in edges:
        fwd.setdefault(a, []).append(b)
        rev.setdefault(b, []).append(a)

    def bfs(start, adj):
        seen = set()
        dq = deque(adj.get(start, []))
        while dq:
            x = dq.popleft()
            if x in seen:
                continue
            seen.add(x)
            dq.extend(adj.get(x, []))
        return seen

    out = []

    def emit(pred, rows):
        rows = sorted(rows)
        for r in rows:
            out.append("%s(%s)" % (pred, ", ".join(str(v) for v in r)))
        out.append("-- %d" % len(rows))

    emit("path", [(1, x) for x in bfs(1, fwd)])
    emit("path", [(x, n) for x in bfs(n, rev)])
    emit("path", [(n // 2, n // 2 + 1)] if n // 2 + 1 in bfs(n // 2, fwd) else [])
    emit("path", [(n // 2 + 1, n // 2)] if n // 2 in bfs(n // 2 + 1, fwd) else [])
    emit("path", [(n, x) for x in bfs(n, fwd)])
    emit("path", [(x, 1) for x in bfs(1, rev)])
    nodes = range(1, n + 1)
    emit("sink", [(x,) for x in nodes if x not in fwd])
    emit("source", [(x,) for x in nodes if x not in rev])
    emit("path", [(x, x) for x in nodes if x in bfs(x, fwd)])
    return "\n".join(out) + "\n"


CHAIN_N = 2000
add("gen_chain_2000_closure", closure_program(chain_edges(CHAIN_N), [
    "?- path(1, X).",
    "?- path(X, %d)." % CHAIN_N,
    "?- path(%d, %d)." % (CHAIN_N // 2, CHAIN_N // 2 + 1),
    "?- path(%d, %d)." % (CHAIN_N // 2 + 1, CHAIN_N // 2),
    "?- path(%d, X)." % CHAIN_N,
    "?- path(X, 1).",
    "sink(X) :- node(X), not hasout(X).",
    "hasout(X) :- edge(X, _).",
    "source(X) :- node(X), not hasin(X).",
    "hasin(X) :- edge(_, X).",
    "?- sink(X).",
    "?- source(X).",
    "?- path(X, X).",
] + [fact("node", i) for i in range(1, CHAIN_N + 1)]), lambda: chain_expected(CHAIN_N))


# ---------------------------------------------------------------------------
# Independent naive oracle
# ---------------------------------------------------------------------------

TOKEN_RE = re.compile(r"\s+|%[^\n]*|:-|\?-|<=|>=|!=|[<>=(),.]|-?\d+|[a-z][a-z0-9_]*|[A-Z][A-Za-z0-9_]*|_")


class OracleError(Exception):
    pass


def oracle_parse(text):
    toks = [t for t in TOKEN_RE.findall(text) if t.strip() and not t.startswith("%")]
    assert "".join(TOKEN_RE.findall(text)) == text, "oracle tokenizer left characters behind"
    pos = 0
    anon = [0]

    def term():
        nonlocal pos
        t = toks[pos]
        pos += 1
        if t == "_":
            anon[0] += 1
            return ("V", "_%d" % anon[0])
        if t[0].isupper():
            return ("V", t)
        if t[0] == "-" or t[0].isdigit():
            return int(t)
        return t

    def atom():
        nonlocal pos
        name = toks[pos]
        pos += 1
        assert toks[pos] == "("
        pos += 1
        args = [term()]
        while toks[pos] == ",":
            pos += 1
            args.append(term())
        assert toks[pos] == ")"
        pos += 1
        return (name, tuple(args))

    rules, queries = [], []
    while pos < len(toks):
        if toks[pos] == "?-":
            pos += 1
            queries.append(atom())
            assert toks[pos] == "."
            pos += 1
            continue
        head = atom()
        body = []
        if toks[pos] == ":-":
            pos += 1
            while True:
                if toks[pos] == "not":
                    pos += 1
                    body.append(("neg", atom()))
                elif toks[pos + 1] == "(":
                    body.append(("pos", atom()))
                else:
                    a = term()
                    op = toks[pos]
                    pos += 1
                    b = term()
                    body.append(("cmp", op, a, b))
                if toks[pos] == ",":
                    pos += 1
                    continue
                break
        assert toks[pos] == "."
        pos += 1
        rules.append((head, body))
    return rules, queries


def is_var(t):
    return isinstance(t, tuple) and t[0] == "V"


def oracle_check(rules):
    for head, body in rules:
        pos_vars = {t for lit in body if lit[0] == "pos" for t in lit[1][1] if is_var(t)}
        need = [t for t in head[1]]
        for lit in body:
            if lit[0] == "neg":
                need += list(lit[1][1])
            elif lit[0] == "cmp":
                need += [lit[2], lit[3]]
        if any(is_var(t) and t not in pos_vars for t in need):
            raise OracleError("unsafe")
    preds = {head[0] for head, _ in rules} | {lit[1][0] for _, body in rules for lit in body if lit[0] != "cmp"}
    stratum = {p: 0 for p in preds}
    for _round in range(len(preds) + 2):
        changed = False
        for head, body in rules:
            for lit in body:
                if lit[0] == "cmp":
                    continue
                want = stratum[lit[1][0]] + (1 if lit[0] == "neg" else 0)
                if want > stratum[head[0]]:
                    stratum[head[0]] = want
                    changed = True
        if not changed:
            break
    else:
        raise OracleError("unstratifiable")
    if max(stratum.values(), default=0) > len(preds):
        raise OracleError("unstratifiable")
    return stratum


def okey(v):
    return (1, v) if isinstance(v, str) else (0, v)


def ocmp(op, a, b):
    return {"<": okey(a) < okey(b), "<=": okey(a) <= okey(b), ">": okey(a) > okey(b),
            ">=": okey(a) >= okey(b), "=": a == b, "!=": a != b}[op]


def oracle_eval(rules, stratum):
    rels = {}
    for head, body in rules:
        rels.setdefault(head[0], set())
        for lit in body:
            if lit[0] != "cmp":
                rels.setdefault(lit[1][0], set())
        if not body:
            rels[head[0]].add(tuple(head[1]))
    for level in sorted(set(stratum.values())):
        level_rules = [(h, b) for h, b in rules if b and stratum[h[0]] == level]
        while True:
            # Per-position value index over every relation, rebuilt each round.
            idx = {}
            for p, tuples in rels.items():
                per = {}
                for t in tuples:
                    for i, v in enumerate(t):
                        per.setdefault((i, v), []).append(t)
                idx[p] = per
            changed = False
            for head, body in level_rules:
                ordered = [l for l in body if l[0] == "pos"] + [l for l in body if l[0] != "pos"]

                def solve(i, env):
                    if i == len(ordered):
                        t = tuple(env[a] if is_var(a) else a for a in head[1])
                        if t not in rels[head[0]]:
                            rels[head[0]].add(t)
                            return True
                        return False
                    lit = ordered[i]
                    any_new = False
                    if lit[0] == "pos":
                        name, args = lit[1]
                        cands = None
                        for j, a in enumerate(args):
                            val = env.get(a) if is_var(a) else a
                            if val is not None:
                                cands = idx[name].get((j, val), [])
                                break
                        if cands is None:
                            cands = list(rels[name])
                        for t in cands:
                            e2 = dict(env)
                            ok = True
                            for a, v in zip(args, t):
                                if is_var(a):
                                    if a in e2:
                                        if e2[a] != v:
                                            ok = False
                                            break
                                    else:
                                        e2[a] = v
                                elif a != v:
                                    ok = False
                                    break
                            if ok and solve(i + 1, e2):
                                any_new = True
                    elif lit[0] == "neg":
                        name, args = lit[1]
                        t = tuple(env[a] if is_var(a) else a for a in args)
                        if t not in rels[name]:
                            any_new = solve(i + 1, env)
                    else:
                        _, op, a, b = lit
                        av = env[a] if is_var(a) else a
                        bv = env[b] if is_var(b) else b
                        if ocmp(op, av, bv):
                            any_new = solve(i + 1, env)
                    return any_new

                if solve(0, {}):
                    changed = True
            if not changed:
                break
    return rels


def naive_oracle(text):
    rules, queries = oracle_parse(text)
    try:
        stratum = oracle_check(rules)
    except OracleError:
        return "error\n"
    rels = oracle_eval(rules, stratum)
    out = []
    for name, args in queries:
        rows = []
        for t in rels.get(name, ()):
            env = {}
            ok = True
            for a, v in zip(args, t):
                if is_var(a):
                    if env.setdefault(a, v) != v:
                        ok = False
                        break
                elif a != v:
                    ok = False
                    break
            if ok:
                rows.append(t)
        rows.sort(key=lambda t: [okey(v) for v in t])
        for t in rows:
            out.append("%s(%s)" % (name, ", ".join(str(v) for v in t)))
        out.append("-- %d" % len(rows))
    return "\n".join(out) + ("\n" if out else "")


# ---------------------------------------------------------------------------
# Driver
# ---------------------------------------------------------------------------

def run_reference(text):
    proc = subprocess.run([sys.executable, REF], input=text.encode(), capture_output=True, timeout=600)
    assert proc.returncode == 0, proc.stderr.decode()
    return proc.stdout.decode()


def main():
    sys.setrecursionlimit(100000)
    os.makedirs(TESTS, exist_ok=True)
    for f in os.listdir(TESTS):
        if f.endswith(".in") or f.endswith(".out"):
            os.remove(os.path.join(TESTS, f))
    names = set()
    total = 0
    for idx, (name, text, oracle) in enumerate(cases, 1):
        assert name not in names, name
        names.add(name)
        base = "%03d_%s" % (idx, name)
        out = run_reference(text)
        if oracle == "naive":
            expect = naive_oracle(text)
        elif oracle is not None:
            expect = oracle()
        else:
            expect = out
        if expect != out:
            sys.stdout.write("MISMATCH in %s\n--- reference:\n%s--- oracle:\n%s" % (base, out[:2000], expect[:2000]))
            sys.exit(1)
        if "error" in name:
            assert out == "error\n", base
        else:
            assert out != "error\n", base
        with open(os.path.join(TESTS, base + ".in"), "w") as f:
            f.write(text)
        with open(os.path.join(TESTS, base + ".out"), "w") as f:
            f.write(out)
        total += len(text) + len(out)
        counts = [int(l[3:]) for l in out.split("\n") if l.startswith("-- ")]
        print("%-48s in=%8d out=%8d queries=%3d max=%7d" % (base, len(text), len(out), len(counts), max(counts, default=0)))
    print("%d tests written, %d bytes" % (len(cases), total))


if __name__ == "__main__":
    main()
