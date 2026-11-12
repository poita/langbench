import itertools
import random


def brute_force_sat(num_vars, clauses):
    """Reference: exhaustively look for a satisfying assignment."""
    for bits in itertools.product([False, True], repeat=num_vars):
        if all(any(bits[abs(l) - 1] == (l > 0) for l in c) for c in clauses):
            return True
    return False


def satisfies(model, clauses):
    value = {abs(l): l > 0 for l in model}
    return all(any(value[abs(l)] == (l > 0) for l in c) for c in clauses)


def random_cnf(rng, num_vars, num_clauses, width=3):
    clauses = []
    for _ in range(num_clauses):
        vs = rng.sample(range(1, num_vars + 1), min(width, num_vars))
        clauses.append([v if rng.random() < 0.5 else -v for v in vs])
    return clauses


def pigeonhole(holes):
    """PHP(holes): holes+1 pigeons into `holes` holes; unsatisfiable."""
    pigeons = holes + 1
    var = lambda p, h: p * holes + h + 1
    clauses = [[var(p, h) for h in range(holes)] for p in range(pigeons)]
    for h in range(holes):
        for p, q in itertools.combinations(range(pigeons), 2):
            clauses.append([-var(p, h), -var(q, h)])
    return pigeons * holes, clauses


def make_rng(seed):
    return random.Random(seed)
