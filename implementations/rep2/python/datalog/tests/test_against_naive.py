"""Cross-check the semi-naive engine against a tiny naive evaluator on random
stratified programs."""

import itertools
import random

import pytest

from datalog import Variable, evaluate, parse
from datalog.analysis import stratify
from datalog.errors import DatalogError
from datalog.syntax import Comparison, Literal, constant_key

CONSTS = [1, 2, 3, -1, "a", "b"]
VARS = ["X", "Y", "Z"]
CMP = {
    "<": lambda a, b: a < b, "<=": lambda a, b: a <= b, ">": lambda a, b: a > b,
    ">=": lambda a, b: a >= b, "=": lambda a, b: a == b, "!=": lambda a, b: a != b,
}


def naive_model(program):
    """Straightforward stratum-by-stratum naive evaluation."""
    key = constant_key
    rels = {}
    for r in program.rules:
        if r.is_fact:
            rels.setdefault(r.head.signature, set()).add(r.head.args)
    consts = sorted(program.constants(), key=key)
    for comp in stratify(program):
        rules = [r for r in program.rules if not r.is_fact and r.head.signature in comp]
        changed = True
        while changed:
            changed = False
            for r in rules:
                names = sorted({v.name for v in _vars(r)})
                for vals in itertools.product(consts, repeat=len(names)):
                    env = dict(zip(names, vals))
                    if _holds(r, env, rels):
                        head = tuple(env[a.name] if isinstance(a, Variable) else a for a in r.head.args)
                        s = rels.setdefault(r.head.signature, set())
                        if head not in s:
                            s.add(head)
                            changed = True
    return rels


def _vars(rule):
    out = list(rule.head.variables())
    for i in rule.body:
        out.extend(i.atom.variables() if isinstance(i, Literal) else i.variables())
    return out


def _holds(rule, env, rels):
    val = lambda t: env[t.name] if isinstance(t, Variable) else t
    for item in rule.body:
        if isinstance(item, Comparison):
            a, b = val(item.left), val(item.right)
            if not CMP[item.op](constant_key(a), constant_key(b)):
                return False
        else:
            row = tuple(val(t) for t in item.atom.args)
            if (row in rels.get(item.atom.signature, ())) == item.negated:
                return False
    return True


# (name, arity, level): positive atoms may use any predicate of level <= the
# head's, negated atoms only strictly lower levels, so programs are stratified
# but still contain (mutual) recursion within a level.
PREDS = [("p", 1, 0), ("q", 2, 0), ("r", 1, 1), ("s", 2, 1), ("t", 1, 2)]


def random_program(rng):
    lines = []
    for _ in range(rng.randint(3, 9)):
        name, ar, _ = rng.choice(PREDS[:2])
        lines.append(f"{name}({', '.join(str(rng.choice(CONSTS)) for _ in range(ar))}).")
    for _ in range(rng.randint(2, 6)):
        hn, har, level = rng.choice(PREDS)
        pos = []
        for _ in range(rng.randint(1, 3)):
            n, a, _ = rng.choice([x for x in PREDS if x[2] <= level])
            pos.append((n, [rng.choice(VARS + ["_"]) for _ in range(a)]))
        bound = [v for _, args in pos for v in args if v in VARS]
        if not bound:
            continue
        body = [f"{n}({', '.join(a)})" for n, a in pos]
        lower = [x for x in PREDS if x[2] < level]
        if lower and rng.random() < 0.5:
            n, a, _ = rng.choice(lower)
            body.append(f"not {n}({', '.join(rng.choice(bound) for _ in range(a))})")
        if rng.random() < 0.4:
            body.append(f"{rng.choice(bound)} {rng.choice(list(CMP))} "
                        f"{rng.choice(bound + [str(c) for c in CONSTS])}")
        head = ", ".join(rng.choice(bound + [str(rng.choice(CONSTS))]) for _ in range(har))
        lines.append(f"{hn}({head}) :- {', '.join(body)}.")
    rng.shuffle(lines)
    return "\n".join(lines)


@pytest.mark.parametrize("seed", range(150))
def test_random_programs(seed):
    rng = random.Random(seed)
    src = random_program(rng)
    program = parse(src)
    try:
        expected = naive_model(program)
    except DatalogError:
        with pytest.raises(DatalogError):
            evaluate(program)
        return
    model = evaluate(program)
    for (name, arity, _) in PREDS:
        want = sorted(expected.get((name, arity), ()), key=lambda t: [constant_key(c) for c in t])
        assert model.relation(name, arity) == want, src


def test_generator_exercises_derivations():
    derived = 0
    for seed in range(150):
        program = parse(random_program(random.Random(seed)))
        facts = sum(r.is_fact for r in program.rules)
        derived += sum(len(v) for v in naive_model(program).values()) > facts
    assert derived > 50
