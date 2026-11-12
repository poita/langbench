import random

import pytest

import datalog
from datalog import evaluate, parse, run

import naive

EX1 = """
edge(1, 2). edge(2, 3). edge(3, 1). edge(3, 4).
path(X, Y) :- edge(X, Y).
path(X, Z) :- edge(X, Y), path(Y, Z).
?- path(1, X).
?- path(4, X).
?- path(X, X).
"""
EX1_OUT = """path(1, 1)
path(1, 2)
path(1, 3)
path(1, 4)
-- 4
-- 0
path(1, 1)
path(2, 2)
path(3, 3)
-- 3
"""

EX2 = """
% nodes and links
node(a). node(b). node(c). node(5). node(-2).
link(a, b). link(b, 5). link(5, 5).
reach(X, Y) :- link(X, Y).
reach(X, Z) :- reach(X, Y), link(Y, Z).
sink(X) :- node(X), not hasout(X).
hasout(X) :- link(X, _).
small(X) :- node(X), X < a.
?- sink(X).
?- small(X).
?- reach(a, X).
?- reach(X, X).
"""
EX2_OUT = """sink(-2)
sink(c)
-- 2
small(-2)
small(5)
-- 2
reach(a, 5)
reach(a, b)
-- 2
reach(5, 5)
-- 1
"""


def test_example_transitive_closure():
    assert run(EX1) == EX1_OUT


def test_example_negation_and_mixed_constants():
    assert run(EX2) == EX2_OUT


def test_error_unstratifiable():
    assert run("edge(1, 2).\nwin(X) :- edge(X, Y), not win(Y).\n?- win(X).") == "error\n"


def test_error_unsafe_suppresses_earlier_output():
    assert run("q(1).\n?- q(X).\np(X) :- q(Y).\n?- p(X).") == "error\n"


def test_error_without_queries():
    assert run("p(X).") == "error\n"


def test_no_queries_no_output():
    assert run("p(1).") == ""
    assert run("") == ""


def test_queries_on_unknown_predicates():
    assert run("?- nothing(X).\n?- p(1, 2).") == "-- 0\n-- 0\n"


def test_same_name_different_arity():
    out = run("r(1). r(2, 3). ?- r(X). ?- r(X, Y). ?- r(X, Y, Z).")
    assert out == "r(1)\n-- 1\nr(2, 3)\n-- 1\n-- 0\n"


def test_constant_and_predicate_namespaces():
    assert run("edge(edge, path). ?- edge(X, Y).") == "edge(edge, path)\n-- 1\n"


def test_order_of_constants():
    text = "v(b). v(a_b). v(aa). v(a). v(a0). v(a_). v(ab). v(7). v(-3). v(10). ?- v(X)."
    out = run(text).splitlines()
    assert out == ["v(-3)", "v(7)", "v(10)", "v(a)", "v(a0)", "v(a_)", "v(a_b)",
                   "v(aa)", "v(ab)", "v(b)", "-- 10"]


def test_comparisons_across_kinds():
    text = """
    v(3). v(a). v(b).
    lt(X, Y) :- v(X), v(Y), X < Y.
    ge(X, Y) :- v(X), v(Y), X >= Y, X != Y.
    eq(X) :- v(X), X = 3.
    ?- lt(X, Y). ?- ge(X, Y). ?- eq(X).
    """
    assert run(text) == (
        "lt(3, a)\nlt(3, b)\nlt(a, b)\n-- 3\n"
        "ge(a, 3)\nge(b, 3)\nge(b, a)\n-- 3\n"
        "eq(3)\n-- 1\n")


def test_ground_comparison_and_constant_only_body():
    assert run("p(a) :- 1 < 2. q(a) :- 2 < 1. ?- p(X). ?- q(X).") == "p(a)\n-- 1\n-- 0\n"


def test_nonlinear_recursion():
    text = "link(1,2). link(2,3). link(3,4). link(4,5)." \
           "link(X, Z) :- link(X, Y), link(Y, Z). ?- link(1, X)."
    assert run(text) == "link(1, 2)\nlink(1, 3)\nlink(1, 4)\nlink(1, 5)\n-- 4\n"


def test_mutual_recursion():
    text = """
    zero(0). succ(0, 1). succ(1, 2). succ(2, 3).
    even(X) :- zero(X).
    even(X) :- succ(Y, X), odd(Y).
    odd(X) :- succ(Y, X), even(Y).
    ?- even(X). ?- odd(X).
    """
    assert run(text) == "even(0)\neven(2)\n-- 2\nodd(1)\nodd(3)\n-- 2\n"


def test_repeated_variable_in_body_atom_and_query():
    text = "e(1,1). e(1,2). e(2,2). loop(X) :- e(X, X). ?- loop(X). ?- e(X, X). ?- e(1, X)."
    assert run(text) == (
        "loop(1)\nloop(2)\n-- 2\ne(1, 1)\ne(2, 2)\n-- 2\ne(1, 1)\ne(1, 2)\n-- 2\n")


def test_facts_and_rules_for_the_same_predicate():
    text = "p(1). p(X) :- q(X). q(2). p(2). ?- p(X)."
    assert run(text) == "p(1)\np(2)\n-- 2\n"


def test_recursive_predicate_with_facts():
    text = "r(1). r(X) :- r(Y), s(Y, X). s(1, 2). s(2, 3). ?- r(X)."
    assert run(text) == "r(1)\nr(2)\nr(3)\n-- 3\n"


def test_body_order_is_irrelevant():
    a = run("q(1). q(2). r(1). p(X) :- not r(X), q(X). ?- p(X).")
    b = run("q(1). q(2). r(1). p(X) :- q(X), not r(X). ?- p(X).")
    assert a == b == "p(2)\n-- 1\n"


def test_wildcard_query_variables():
    assert run("p(1, 2). p(3, 4). ?- p(_, _).") == "p(1, 2)\np(3, 4)\n-- 2\n"


def test_queries_answered_in_source_order():
    assert run("?- p(X). p(1). ?- q(X). q(2).") == "p(1)\n-- 1\nq(2)\n-- 1\n"


def test_library_api():
    model = evaluate(parse(EX2))
    assert model.query("reach(a, X)") == [("a", 5), ("a", "b")]
    assert model.relation("sink", 1) == [(-2,), ("c",)]
    assert model.query("sink(unseen)") == []
    assert ("link", 2) in model.predicates()


def test_library_errors():
    with pytest.raises(datalog.UnsafeRuleError):
        evaluate(parse("p(X)."))
    with pytest.raises(datalog.StratificationError):
        evaluate(parse("p(X) :- q(X), not p(X). q(1)."))


def test_deep_chain_closure():
    n = 300
    facts = "".join(f"edge({i}, {i + 1})." for i in range(1, n))
    text = facts + "path(X,Y):-edge(X,Y). path(X,Z):-edge(X,Y),path(Y,Z). ?- path(X, Y)."
    assert run(text).splitlines()[-1] == f"-- {n * (n - 1) // 2}"


# -- randomised differential test against the naive evaluator -------------------

CONSTS = ["a", "b", "c", "1", "2", "-1"]
VARS = ["X", "Y", "Z"]


def random_program(rng):
    preds = [("p", 1), ("q", 2), ("r", 2), ("s", 1), ("t", 2)]
    lines = []
    for name, arity in preds[:3]:   # base facts for the first three predicates
        for _ in range(rng.randint(2, 8)):
            lines.append(f"{name}({', '.join(rng.choice(CONSTS) for _ in range(arity))}).")
    for _ in range(rng.randint(1, 7)):
        head_name, head_arity = rng.choice(preds)
        body, pos_vars = [], []
        for _ in range(rng.randint(1, 3)):
            n, a = rng.choice(preds)
            args = [rng.choice(VARS + CONSTS[:2] + ["_"]) for _ in range(a)]
            pos_vars += [x for x in args if x in VARS]
            body.append(f"{n}({', '.join(args)})")
        if not pos_vars:
            continue
        if rng.random() < 0.15:
            n, a = rng.choice(preds)
            body.append(f"not {n}({', '.join(rng.choice(pos_vars) for _ in range(a))})")
        if rng.random() < 0.4:
            body.append(f"{rng.choice(pos_vars)} {rng.choice(['<', '<=', '>', '>=', '=', '!='])} "
                        f"{rng.choice(pos_vars + CONSTS)}")
        head = ", ".join(rng.choice(pos_vars) for _ in range(head_arity))
        lines.append(f"{head_name}({head}) :- {', '.join(body)}.")
    return "\n".join(lines)


@pytest.mark.parametrize("seed", range(300))
def test_matches_naive_evaluator(seed):
    rng = random.Random(seed)
    text = random_program(rng)
    program = parse(text)
    try:
        expected = naive.model(program)
    except datalog.StratificationError:
        with pytest.raises(datalog.StratificationError):
            evaluate(program)
        return
    model = evaluate(program)
    for name, arity in [("p", 1), ("q", 2), ("r", 2), ("s", 1), ("t", 2)]:
        atom = datalog.parse_atom(f"{name}({', '.join(['_'] * arity)})")
        assert model.query(atom) == naive.query(expected, atom), text
