#!/usr/bin/env python3
"""Reference Datalog engine for the `datalog` problem.

Reads a program on stdin, checks safety and stratifiability, evaluates the
stratified model bottom-up with semi-naive iteration over the strongly
connected components of the predicate dependency graph, and answers the
queries in input order.

Constants are Python ints (integers) or strs (identifiers). Variables inside a
parsed clause are represented as Var objects; the anonymous `_` becomes a
fresh Var each time it occurs.
"""
import sys

sys.setrecursionlimit(100000)


# ---------------------------------------------------------------------------
# Lexer / parser
# ---------------------------------------------------------------------------

class Var:
    __slots__ = ("name",)

    def __init__(self, name):
        self.name = name


PUNCT2 = {":-", "?-", "<=", ">=", "!="}
PUNCT1 = set("(),.<>=")


def tokenize(text):
    toks = []
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c in " \t\r\n":
            i += 1
        elif c == "%":
            while i < n and text[i] != "\n":
                i += 1
        elif text[i:i + 2] in PUNCT2:
            toks.append(("p", text[i:i + 2]))
            i += 2
        elif c in PUNCT1:
            toks.append(("p", c))
            i += 1
        elif c == "-" or c.isdigit():
            j = i + 1
            while j < n and text[j].isdigit():
                j += 1
            toks.append(("int", int(text[i:j])))
            i = j
        elif c.isalpha() or c == "_":
            j = i + 1
            while j < n and (text[j].isalnum() or text[j] == "_"):
                j += 1
            word = text[i:j]
            if word == "not":
                toks.append(("p", "not"))
            elif c.islower():
                toks.append(("id", word))
            else:
                toks.append(("var", word))
            i = j
        else:
            raise ValueError("bad character %r" % c)
    return toks


class Parser:
    def __init__(self, toks):
        self.toks = toks
        self.pos = 0
        self.anon = 0
        self.vars = {}

    def peek(self):
        return self.toks[self.pos] if self.pos < len(self.toks) else (None, None)

    def take(self):
        t = self.toks[self.pos]
        self.pos += 1
        return t

    def expect(self, val):
        t = self.take()
        if t != ("p", val):
            raise ValueError("expected %r" % val)

    def term(self):
        kind, val = self.take()
        if kind == "int" or kind == "id":
            return val
        if kind == "var":
            if val == "_":
                self.anon += 1
                return Var("_%d" % self.anon)
            v = self.vars.get(val)
            if v is None:
                v = self.vars[val] = Var(val)
            return v
        raise ValueError("bad term")

    def atom_after_name(self, name):
        self.expect("(")
        args = [self.term()]
        while self.peek() == ("p", ","):
            self.take()
            args.append(self.term())
        self.expect(")")
        return (name, tuple(args))

    def atom(self):
        kind, name = self.take()
        if kind != "id":
            raise ValueError("expected predicate")
        return self.atom_after_name(name)

    def literal(self):
        """Returns ('pos', atom), ('neg', atom) or ('cmp', op, a, b)."""
        if self.peek() == ("p", "not"):
            self.take()
            return ("neg", self.atom())
        kind, val = self.peek()
        if kind == "id" and self.pos + 1 < len(self.toks) and self.toks[self.pos + 1] == ("p", "("):
            return ("pos", self.atom())
        a = self.term()
        kind, op = self.take()
        if kind != "p" or op not in ("<", "<=", ">", ">=", "=", "!="):
            raise ValueError("expected comparison operator")
        b = self.term()
        return ("cmp", op, a, b)

    def program(self):
        """Returns (rules, queries); a rule is (head_atom, [literals])."""
        rules, queries = [], []
        while self.peek()[0] is not None:
            self.vars = {}
            if self.peek() == ("p", "?-"):
                self.take()
                queries.append(self.atom())
                self.expect(".")
                continue
            head = self.atom()
            body = []
            if self.peek() == ("p", ":-"):
                self.take()
                body.append(self.literal())
                while self.peek() == ("p", ","):
                    self.take()
                    body.append(self.literal())
            self.expect(".")
            rules.append((head, body))
        return rules, queries


# ---------------------------------------------------------------------------
# Static checks: safety and stratification
# ---------------------------------------------------------------------------

def is_safe(rule):
    head, body = rule
    positive = set()
    for lit in body:
        if lit[0] == "pos":
            for t in lit[1][1]:
                if isinstance(t, Var):
                    positive.add(t)
    for t in head[1]:
        if isinstance(t, Var) and t not in positive:
            return False
    for lit in body:
        if lit[0] == "neg":
            terms = lit[1][1]
        elif lit[0] == "cmp":
            terms = (lit[2], lit[3])
        else:
            continue
        for t in terms:
            if isinstance(t, Var) and t not in positive:
                return False
    return True


def sccs(preds, edges):
    """Tarjan's algorithm; returns SCCs in reverse topological order
    (a component is listed after every component it depends on)."""
    index = {}
    low = {}
    stack = []
    on_stack = set()
    out = []
    counter = [0]

    def visit(v):
        index[v] = low[v] = counter[0]
        counter[0] += 1
        stack.append(v)
        on_stack.add(v)
        for w, _neg in edges.get(v, ()):
            if w not in index:
                visit(w)
                low[v] = min(low[v], low[w])
            elif w in on_stack:
                low[v] = min(low[v], index[w])
        if low[v] == index[v]:
            comp = []
            while True:
                w = stack.pop()
                on_stack.discard(w)
                comp.append(w)
                if w == v:
                    break
            out.append(comp)

    for p in preds:
        if p not in index:
            visit(p)
    return out


def stratify(rules, preds):
    """Returns the SCCs of the dependency graph in evaluation order, or None
    when some cycle contains a negative edge.

    Edges point from a head predicate to the predicates its body reads, so
    Tarjan's reverse-topological output lists every component after the
    components it depends on."""
    edges = {p: [] for p in preds}
    for head, body in rules:
        for lit in body:
            if lit[0] in ("pos", "neg"):
                edges[head[0]].append((lit[1][0], lit[0] == "neg"))
    comps = sccs(sorted(preds), edges)
    comp_of = {}
    for i, comp in enumerate(comps):
        for p in comp:
            comp_of[p] = i
    for p, outs in edges.items():
        for q, neg in outs:
            if neg and comp_of[p] == comp_of[q]:
                return None
    return comps


# ---------------------------------------------------------------------------
# Relations with on-demand hash indexes
# ---------------------------------------------------------------------------

class Rel:
    __slots__ = ("tuples", "indexes")

    def __init__(self, tuples=None):
        self.tuples = set(tuples) if tuples else set()
        self.indexes = {}

    def index(self, positions):
        idx = self.indexes.get(positions)
        if idx is None:
            idx = {}
            for t in self.tuples:
                key = tuple([t[p] for p in positions])
                lst = idx.get(key)
                if lst is None:
                    idx[key] = [t]
                else:
                    lst.append(t)
            self.indexes[positions] = idx
        return idx

    def add_all(self, new):
        """Adds tuples known to be absent, keeping every existing index current."""
        self.tuples.update(new)
        for positions, idx in self.indexes.items():
            for t in new:
                key = tuple([t[p] for p in positions])
                lst = idx.get(key)
                if lst is None:
                    idx[key] = [t]
                else:
                    lst.append(t)


# ---------------------------------------------------------------------------
# Rule compilation into join plans
# ---------------------------------------------------------------------------

def sort_key(v):
    return (1, v) if isinstance(v, str) else (0, v)


def compare(op, a, b):
    if op == "=":
        return a == b
    if op == "!=":
        return a != b
    ka, kb = sort_key(a), sort_key(b)
    if op == "<":
        return ka < kb
    if op == "<=":
        return ka <= kb
    if op == ">":
        return ka > kb
    return ka >= kb


def compile_rule(rule, delta_literal=None):
    """Builds an evaluation plan for a rule.

    delta_literal is the index (within the body) of the positive atom that is
    read from the delta relation instead of the full one; that atom is joined
    first. Negated atoms and comparisons are scheduled as soon as all their
    variables are bound.
    """
    head, body = rule
    var_ids = {}

    def vid(v):
        if v not in var_ids:
            var_ids[v] = len(var_ids)
        return var_ids[v]

    positives = [i for i, lit in enumerate(body) if lit[0] == "pos"]
    if delta_literal is not None:
        positives.remove(delta_literal)
        positives.insert(0, delta_literal)
    pending = [lit for lit in body if lit[0] != "pos"]
    bound = set()
    steps = []

    def flush_pending():
        remaining = []
        for lit in pending:
            terms = lit[1][1] if lit[0] == "neg" else (lit[2], lit[3])
            if all((not isinstance(t, Var)) or t in bound for t in terms):
                if lit[0] == "neg":
                    getters = tuple((True, var_ids[t]) if isinstance(t, Var) else (False, t) for t in terms)
                    steps.append(("neg", lit[1][0], getters))
                else:
                    ga = (True, var_ids[lit[2]]) if isinstance(lit[2], Var) else (False, lit[2])
                    gb = (True, var_ids[lit[3]]) if isinstance(lit[3], Var) else (False, lit[3])
                    steps.append(("cmp", lit[1], ga, gb))
            else:
                remaining.append(lit)
        pending[:] = remaining

    flush_pending()
    for i in positives:
        pred, args = body[i][1]
        key_positions, key_getters, binds, checks = [], [], [], []
        # A variable repeated inside one atom is checked against the position
        # of its first occurrence in the same tuple.
        seen_here = {}
        for pos, t in enumerate(args):
            if not isinstance(t, Var):
                key_positions.append(pos)
                key_getters.append((False, t))
            elif t in bound:
                key_positions.append(pos)
                key_getters.append((True, var_ids[t]))
            elif t in seen_here:
                checks.append((pos, seen_here[t]))
            else:
                seen_here[t] = pos
                binds.append((pos, vid(t)))
        for t in seen_here:
            bound.add(t)
        steps.append(("atom", pred, i == delta_literal, tuple(key_positions), tuple(key_getters), tuple(binds), tuple(checks)))
        flush_pending()
    assert not pending, "unsafe rule reached evaluation"
    head_getters = tuple((True, var_ids[t]) if isinstance(t, Var) else (False, t) for t in head[1])
    return (head[0], len(var_ids), steps, head_getters)


def run_plan(plan, rels, delta, out):
    """Appends every head tuple derivable under the plan to `out`."""
    _head_pred, nvars, steps, head_getters = plan
    env = [None] * nvars
    nsteps = len(steps)

    def go(i):
        if i == nsteps:
            out.append(tuple([env[x] if isv else x for isv, x in head_getters]))
            return
        step = steps[i]
        kind = step[0]
        if kind == "atom":
            _, pred, use_delta, key_positions, key_getters, binds, checks = step
            rel = delta if use_delta else rels.get(pred)
            if rel is None:
                return
            if key_positions:
                key = tuple([env[x] if isv else x for isv, x in key_getters])
                cands = rel.index(key_positions).get(key)
                if cands is None:
                    return
            else:
                cands = rel.tuples
            nxt = i + 1
            for t in cands:
                ok = True
                for pos, first in checks:
                    if t[pos] != t[first]:
                        ok = False
                        break
                if not ok:
                    continue
                for pos, v in binds:
                    env[v] = t[pos]
                go(nxt)
        elif kind == "neg":
            _, pred, getters = step
            rel = rels.get(pred)
            key = tuple([env[x] if isv else x for isv, x in getters])
            if rel is None or key not in rel.tuples:
                go(i + 1)
        else:
            _, op, ga, gb = step
            a = env[ga[1]] if ga[0] else ga[1]
            b = env[gb[1]] if gb[0] else gb[1]
            if compare(op, a, b):
                go(i + 1)

    go(0)


# ---------------------------------------------------------------------------
# Evaluation
# ---------------------------------------------------------------------------

def evaluate(rules, comps):
    rels = {}
    # Facts (rules without a body) seed their relations directly.
    for head, body in rules:
        if not body:
            rels.setdefault(head[0], Rel()).tuples.add(tuple(head[1]))
    for comp in comps:
        members = set(comp)
        comp_rules = [r for r in rules if r[0][0] in members and r[1]]
        if not comp_rules:
            continue
        for p in members:
            rels.setdefault(p, Rel())
        # Round 0: every rule of the component against the current relations.
        derived = {p: [] for p in members}
        for r in comp_rules:
            run_plan(compile_rule(r), rels, None, derived[r[0][0]])
        delta = {}
        for p in members:
            new = set(derived[p]) - rels[p].tuples
            rels[p].add_all(new)
            delta[p] = new
        # Semi-naive rounds: one plan per recursive body atom, reading it from the delta.
        variants = []
        for r in comp_rules:
            for i, lit in enumerate(r[1]):
                if lit[0] == "pos" and lit[1][0] in members:
                    variants.append((lit[1][0], compile_rule(r, i)))
        while any(delta.values()):
            delta_rels = {p: Rel(s) for p, s in delta.items() if s}
            derived = {p: [] for p in members}
            for dpred, plan in variants:
                drel = delta_rels.get(dpred)
                if drel is not None:
                    run_plan(plan, rels, drel, derived[plan[0]])
            delta = {}
            for p in members:
                new = set(derived[p]) - rels[p].tuples
                rels[p].add_all(new)
                delta[p] = new
    return rels


def answer(query, rels):
    pred, args = query
    rel = rels.get(pred)
    if rel is None:
        return []
    first = {}
    consts, same = [], []
    for pos, t in enumerate(args):
        if isinstance(t, Var):
            if t in first:
                same.append((pos, first[t]))
            else:
                first[t] = pos
        else:
            consts.append((pos, t))
    result = []
    for t in rel.tuples:
        if all(t[p] == c for p, c in consts) and all(t[p] == t[q] for p, q in same):
            result.append(t)
    result.sort(key=lambda t: [sort_key(v) for v in t])
    return result


def main():
    text = sys.stdin.read()
    rules, queries = Parser(tokenize(text)).program()
    if not all(is_safe(r) for r in rules):
        sys.stdout.write("error\n")
        return
    preds = set()
    for head, body in rules:
        preds.add(head[0])
        for lit in body:
            if lit[0] in ("pos", "neg"):
                preds.add(lit[1][0])
    for q in queries:
        preds.add(q[0])
    comps = stratify(rules, preds)
    if comps is None:
        sys.stdout.write("error\n")
        return
    rels = evaluate(rules, comps)
    out = []
    for q in queries:
        rows = answer(q, rels)
        for t in rows:
            out.append("%s(%s)\n" % (q[0], ", ".join(str(v) for v in t)))
        out.append("-- %d\n" % len(rows))
    sys.stdout.write("".join(out))


if __name__ == "__main__":
    main()
