from datalog import Atom, Variable, evaluate, parse


def model_of(src):
    return evaluate(parse(src))


def test_transitive_closure():
    m = model_of("""
        edge(1, 2). edge(2, 3). edge(3, 1). edge(3, 4).
        path(X, Y) :- edge(X, Y).
        path(X, Z) :- edge(X, Y), path(Y, Z).""")
    assert m.query(Atom("path", (1, Variable("X")))) == [(1, 1), (1, 2), (1, 3), (1, 4)]
    assert m.query(Atom("path", (4, Variable("X")))) == []
    assert m.query(Atom("path", (Variable("X"), Variable("X")))) == [(1, 1), (2, 2), (3, 3)]


def test_non_linear_rule():
    m = model_of("""
        link(1, 2). link(2, 3). link(3, 4). link(4, 5). link(5, 6).
        link(X, Z) :- link(X, Y), link(Y, Z).""")
    assert len(m.relation("link", 2)) == 15


def test_mutual_recursion_both_positions():
    m = model_of("""
        a(1). b(2).
        a(X) :- b(X), c(X).
        b(X) :- a(Y), a(Z), pair(Y, Z, X).
        pair(1, 1, 2). pair(2, 1, 3). pair(2, 2, 4). pair(3, 1, 5).
        c(2). c(3).
        a(X) :- b(X).""")
    assert m.relation("b", 1) == [(2,), (3,), (4,), (5,)]


def test_negation_and_comparisons_with_mixed_constants():
    m = model_of("""
        node(a). node(b). node(c). node(5). node(-2).
        link(a, b). link(b, 5). link(5, 5).
        sink(X) :- node(X), not hasout(X).
        hasout(X) :- link(X, _).
        small(X) :- node(X), X < a.""")
    assert m.relation("sink", 1) == [(-2,), ("c",)]
    assert m.relation("small", 1) == [(-2,), (5,)]


def test_ordering_of_identifiers():
    m = model_of("p(b). p(a_b). p(aa). p(a0). p(a). p(ab). p(a_). p(7). p(-3).")
    assert m.relation("p", 1) == [(-3,), (7,), ("a",), ("a0",), ("a_",), ("a_b",), ("aa",), ("ab",), ("b",)]


def test_repeated_variable_in_body_atom():
    m = model_of("edge(1, 1). edge(1, 2). loop(X) :- edge(X, X).")
    assert m.relation("loop", 1) == [(1,)]


def test_constants_in_body_and_head():
    m = model_of("e(1, a). e(2, b). p(X, z) :- e(X, a). q(1) :- e(2, b).")
    assert m.relation("p", 2) == [(1, "z")]
    assert m.relation("q", 1) == [(1,)]


def test_rule_without_positive_atoms():
    m = model_of("p(1) :- 1 < 2. q(1) :- 2 < 1. r(1) :- not s(3).")
    assert m.relation("p", 1) == [(1,)]
    assert m.relation("q", 1) == []
    assert m.relation("r", 1) == [(1,)]


def test_facts_and_rules_for_same_predicate():
    m = model_of("p(1). q(2). p(X) :- q(X). p(X) :- q(X).")
    assert m.relation("p", 1) == [(1,), (2,)]


def test_unknown_predicate_and_constant():
    m = model_of("p(1).")
    assert m.query(Atom("nope", (Variable("X"),))) == []
    assert m.query(Atom("p", ("never_seen",))) == []
    assert m.query(Atom("p", (1, 2))) == []


def test_query_fully_bound():
    m = model_of("p(1, 2). p(2, 3).")
    assert m.query(Atom("p", (1, 2))) == [(1, 2)]
    assert m.query(Atom("p", (1, 3))) == []


def test_evaluation_over_stratum_with_facts_in_recursive_predicate():
    m = model_of("""
        reach(1). reach(X) :- reach(Y), e(Y, X).
        e(1, 2). e(2, 3). e(5, 6).
        unreached(X) :- n(X), not reach(X).
        n(1). n(2). n(3). n(5). n(6).""")
    assert m.relation("unreached", 1) == [(5,), (6,)]
