"""A deliberately simple reference evaluator used to cross-check the engine.

Works on the surface syntax with Python values (no ranks): naive fixpoint per
stratum, brute-force substitution search.
"""
from datalog.analysis import stratify
from datalog.constants import sort_key
from datalog.syntax import Atom, Comparison, Const, Not, Var


def _val(t, env):
    return t.value if isinstance(t, Const) else env[t.name]


def _solve(body, env, db):
    if not body:
        yield env
        return
    lit, rest = body[0], body[1:]
    if isinstance(lit, Atom):
        for row in list(db.get(lit.key, ())):
            e = dict(env)
            ok = True
            for t, v in zip(lit.args, row):
                if isinstance(t, Const):
                    ok = t.value == v
                elif t.name in e:
                    ok = e[t.name] == v
                else:
                    e[t.name] = v
                if not ok:
                    break
            if ok:
                yield from _solve(rest, e, db)
    else:
        yield from _solve(rest, env, db) if _holds(lit, env, db) else ()


def _holds(lit, env, db):
    if isinstance(lit, Not):
        return tuple(_val(t, env) for t in lit.atom.args) not in db.get(lit.atom.key, ())
    a, b = sort_key(_val(lit.left, env)), sort_key(_val(lit.right, env))
    return {"<": a < b, "<=": a <= b, ">": a > b, ">=": a >= b, "=": a == b, "!=": a != b}[lit.op]


def model(program):
    db = {}
    comps = stratify(program.rules)
    for comp in comps:
        rs = [r for r in program.rules if r.head.key in comp]
        changed = True
        while changed:
            changed = False
            for r in rs:
                # positive atoms first so negations/comparisons see bound variables
                body = sorted(r.body, key=lambda l: not isinstance(l, Atom))
                for env in list(_solve(body, {}, db)):
                    row = tuple(_val(t, env) for t in r.head.args)
                    s = db.setdefault(r.head.key, set())
                    if row not in s:
                        s.add(row)
                        changed = True
    return db


def query(db, atom):
    out = set()
    for row in db.get(atom.key, ()):
        env, ok = {}, True
        for t, v in zip(atom.args, row):
            if isinstance(t, Const):
                ok = t.value == v
            elif t.name in env:
                ok = env[t.name] == v
            else:
                env[t.name] = v
            if not ok:
                break
        if ok:
            out.add(row)
    return sorted(out, key=lambda r: [sort_key(v) for v in r])
