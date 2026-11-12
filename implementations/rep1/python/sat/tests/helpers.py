import itertools
import random


def satisfies(clauses, model):
    return all(any(model[abs(l) - 1] == (l > 0) for l in c) for c in clauses)


def brute_force_sat(num_vars, clauses):
    for bits in itertools.product([False, True], repeat=num_vars):
        if satisfies(clauses, bits):
            return True
    return False


def random_cnf(rng, num_vars, num_clauses, width=3):
    clauses = []
    for _ in range(num_clauses):
        k = rng.randint(1, width)
        clauses.append([rng.choice([-1, 1]) * rng.randint(1, num_vars) for _ in range(k)])
    return clauses


def pigeonhole(n):
    """PHP(n): n+1 pigeons into n holes (UNSAT)."""
    var = lambda p, h: p * n + h + 1
    clauses = [[var(p, h) for h in range(n)] for p in range(n + 1)]
    for h in range(n):
        for p1 in range(n + 1):
            for p2 in range(p1 + 1, n + 1):
                clauses.append([-var(p1, h), -var(p2, h)])
    return (n + 1) * n, clauses
