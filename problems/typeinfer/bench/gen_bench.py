#!/usr/bin/env python3
"""Generates the performance benchmark inputs for `typeinfer`.

Writes bench/NNN_name.in and bench/NNN_name.out in the same layout as
tests/, so `run_tests.py typeinfer --tests-dir problems/typeinfer/bench`
works. Every generator uses a fixed seed, so re-running reproduces the
inputs byte for byte. Expected outputs come from reference/main.py (about
two minutes in total).

Usage: gen_bench.py [--long] [--no-expected] [NNN prefixes...]
"""
import os
import random
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PROBLEM = os.path.dirname(HERE)
REF = os.path.join(PROBLEM, 'reference', 'main.py')
MAX_BYTES = 1_200_000
MAX_DECLS = 6000


# ---------------------------------------------------------------------------
# 001: a large ordinary program, as many bytes as the input limit allows: a
# library of well-typed first-order and higher-order functions generated in
# a type-directed way (so almost every declaration type-checks, as in real
# code), interleaved with a state-monad combinator library whose definitions
# build on each other. About 3% of declarations contain one type error.
# ---------------------------------------------------------------------------
INT = ('int',); BOOL = ('bool',); UNIT = ('unit',)
def L(t): return ('list', t)
def P(a, b): return ('tup', a, b)
def F(a, b): return ('fn', a, b)

SIG_TYPES = [INT, INT, INT, BOOL, BOOL, L(INT), L(INT), L(BOOL), P(INT, BOOL), P(INT, INT),
             L(L(INT)), L(P(INT, BOOL)), F(INT, INT), F(INT, BOOL), P(L(INT), INT)]

TYPED_PRELUDE = '''let id x = x;;
let const x y = x;;
let twice f x = f (f x);;
let compose f g x = f (g x);;
let flip f x y = f y x;;
let swap p = (snd p, fst p);;
let rec append l1 l2 = if null l1 then l2 else hd l1 :: append (tl l1) l2;;
let rec filter p l = if null l then [] else if p (hd l) then hd l :: filter p (tl l) else filter p (tl l);;
let rec range a b = if a > b then [] else a :: range (a + 1) b;;
let rec foldr f l acc = if null l then acc else f (hd l) (foldr f (tl l) acc);;
let sum l = fold (fun a b -> a + b) 0 l;;
let rec zip l1 l2 = if null l1 || null l2 then [] else (hd l1, hd l2) :: zip (tl l1) (tl l2);;
let rev l = fold (fun acc x -> x :: acc) [] l;;
let concat ls = foldr append ls [];;
let exists p l = fold (fun acc x -> acc || p x) false l;;
let all p l = fold (fun acc x -> acc && p x) true l;;
let rec nth l n = if n = 0 then hd l else nth (tl l) (n - 1);;
let option_map f d l = if null l then d else f (hd l);;
'''.strip().split('\n')


class TypedGen:
    """Type-directed generator of well-typed declarations that use the
    prelude's polymorphic helpers at many different types."""

    def __init__(self, rng):
        self.rng = rng
        self.funs = []      # (name, [param types], result type)
        self.vals = []      # (name, type) top-level values
        self.k = 0
        self.v = 0

    def fresh(self):
        self.v += 1
        return 'v%d' % self.v

    def pick_type(self):
        return self.rng.choice(SIG_TYPES)

    def leaf(self, t, env):
        rng = self.rng
        cands = [n for n, ty in env if ty == t]
        if cands and rng.random() < 0.7:
            return rng.choice(cands)
        k = t[0]
        if k == 'int':
            return str(rng.choice([0, 1, 2, 3, 10, 42, 100]))
        if k == 'bool':
            return rng.choice(['true', 'false'])
        if k == 'list':
            return '[]'
        if k == 'tup':
            return '(%s, %s)' % (self.leaf(t[1], env), self.leaf(t[2], env))
        x = self.fresh()
        return '(fun %s -> %s)' % (x, self.leaf(t[2], env + [(x, t[1])]))

    def gen(self, t, env, d):
        if d <= 0:
            return self.leaf(t, env)
        rng = self.rng
        r = rng.random()
        if r < 0.12:
            return self.leaf(t, env)
        if r < 0.22:
            x = self.fresh()
            s = self.pick_type()
            return '(let %s = %s in %s)' % (x, self.gen(s, env, d - 1), self.gen(t, env + [(x, s)], d - 1))
        if r < 0.30:
            return '(if %s then %s else %s)' % (self.gen(BOOL, env, d - 1), self.gen(t, env, d - 1), self.gen(t, env, d - 1))
        if r < 0.45:
            fs = [f for f in self.funs if f[2] == t]
            if fs:
                name, ps, _ = rng.choice(fs[-60:] if rng.random() < 0.7 else fs)
                return '(%s %s)' % (name, ' '.join(self.gen(p, env, d - 2) for p in ps))
        if r < 0.55:
            return self.poly(t, env, d)
        return self.specific(t, env, d)

    def poly(self, t, env, d):
        """Uses of polymorphic prelude helpers producing a value of type t."""
        rng = self.rng
        r = rng.random()
        g = lambda ty: self.gen(ty, env, d - 1)
        if r < 0.15:
            return '(id %s)' % g(t)
        if r < 0.3:
            x = self.fresh()
            return '(twice (fun %s -> %s) %s)' % (x, self.gen(t, env + [(x, t)], d - 1), g(t))
        if r < 0.4:
            return '(const %s %s)' % (g(t), g(self.pick_type()))
        if r < 0.55:
            s = self.pick_type()
            x, y = self.fresh(), self.fresh()
            return '(compose (fun %s -> %s) (fun %s -> %s) %s)' % (
                x, self.gen(t, env + [(x, s)], d - 1), y, self.gen(s, env + [(y, INT)], d - 1), g(INT))
        if r < 0.65:
            s = self.pick_type()
            return '(fst (swap (%s, %s)))' % (g(s), g(t)) if rng.random() < 0.5 else '(snd (swap (%s, %s)))' % (g(t), g(s))
        if r < 0.75:
            s = self.pick_type()
            x, y = self.fresh(), self.fresh()
            return '(flip (fun %s %s -> %s) %s %s)' % (x, y, self.gen(t, env + [(x, s), (y, INT)], d - 1), g(INT), g(s))
        if r < 0.85:
            return '(nth %s %s)' % (g(L(t)), g(INT))
        x = self.fresh()
        s = self.pick_type()
        return '(option_map (fun %s -> %s) %s %s)' % (x, self.gen(t, env + [(x, s)], d - 1), g(t), g(L(s)))

    def specific(self, t, env, d):
        rng = self.rng
        g = lambda ty: self.gen(ty, env, d - 1)
        k = t[0]
        r = rng.random()
        if k == 'int':
            if r < 0.4:
                return '(%s %s %s)' % (self.atom(INT, env, d), rng.choice('+-*/'), self.atom(INT, env, d))
            if r < 0.55:
                return '(length %s)' % g(L(self.pick_type()))
            if r < 0.65:
                return '(sum %s)' % g(L(INT))
            if r < 0.75:
                return '(fst %s)' % g(P(INT, self.pick_type()))
            if r < 0.85:
                a, x = self.fresh(), self.fresh()
                s = self.pick_type()
                return '(fold (fun %s %s -> %s) %s %s)' % (a, x, self.gen(INT, env + [(a, INT), (x, s)], d - 1), g(INT), g(L(s)))
            return '(hd %s)' % g(L(INT))
        if k == 'bool':
            if r < 0.35:
                return '(%s %s %s)' % (self.atom(INT, env, d), rng.choice(['=', '<', '>', '<=', '>=']), self.atom(INT, env, d))
            if r < 0.55:
                return '(%s %s %s)' % (self.atom(BOOL, env, d), rng.choice(['&&', '||']), self.atom(BOOL, env, d))
            if r < 0.65:
                return '(not %s)' % g(BOOL)
            if r < 0.75:
                return '(null %s)' % g(L(self.pick_type()))
            x = self.fresh()
            s = self.pick_type()
            return '(%s (fun %s -> %s) %s)' % (rng.choice(['exists', 'all']), x, self.gen(BOOL, env + [(x, s)], d - 1), g(L(s)))
        if k == 'list':
            e = t[1]
            if r < 0.2:
                n = rng.randint(1, 4)
                return '[%s]' % '; '.join(g(e) for _ in range(n))
            if r < 0.35:
                return '(%s :: %s)' % (self.atom(e, env, d), self.atom(t, env, d))
            if r < 0.5:
                x = self.fresh()
                s = self.pick_type()
                return '(map (fun %s -> %s) %s)' % (x, self.gen(e, env + [(x, s)], d - 1), g(L(s)))
            if r < 0.6:
                return '(append %s %s)' % (g(t), g(t))
            if r < 0.7:
                x = self.fresh()
                return '(filter (fun %s -> %s) %s)' % (x, self.gen(BOOL, env + [(x, e)], d - 1), g(t))
            if r < 0.75:
                return '(rev %s)' % g(t)
            if r < 0.8:
                return '(concat %s)' % g(L(t))
            if r < 0.85 and e == INT:
                return '(range %s %s)' % (g(INT), g(INT))
            if r < 0.9 and e[0] == 'tup':
                return '(zip %s %s)' % (g(L(e[1])), g(L(e[2])))
            return '(tl %s)' % g(t)
        if k == 'tup':
            if r < 0.7:
                return '(%s, %s)' % (g(t[1]), g(t[2]))
            if r < 0.85:
                return '(swap %s)' % g(P(t[2], t[1]))
            return '(hd %s)' % g(L(t))
        x = self.fresh()
        if r < 0.7:
            return '(fun %s -> %s)' % (x, self.gen(t[2], env + [(x, t[1])], d - 1))
        m = self.fresh()
        return '(compose (fun %s -> %s) (fun %s -> %s))' % (
            x, self.gen(t[2], env + [(x, INT)], d - 1), m, self.gen(INT, env + [(m, t[1])], d - 1))

    def atom(self, t, env, d):
        return self.gen(t, env, d - 1)

    def declaration(self, depth):
        rng = self.rng
        self.v = 0
        r = rng.random()
        k = self.k
        self.k += 1
        if r < 0.12:
            t = self.pick_type()
            return '%s;;' % self.gen(t, list(self.vals), depth)
        if r < 0.25:
            t = self.pick_type()
            name = 'c%d' % k
            text = 'let %s = %s;;' % (name, self.gen(t, list(self.vals[-30:]), depth))
            self.vals.append((name, t))
            return text
        name = 'f%d' % k
        ps = [self.pick_type() for _ in range(rng.randint(1, 3))]
        ret = self.pick_type()
        pn = ['p%d' % i for i in range(len(ps))]
        env = list(self.vals[-30:]) + list(zip(pn, ps))
        if r < 0.45:
            ps[0] = INT
            env = list(self.vals[-30:]) + list(zip(pn, ps))
            self.funs.append((name, ps, ret))
            base = self.gen(ret, env, depth - 2)
            rec = '%s (p0 - 1) %s' % (name, ' '.join(self.gen(p, env, 1) for p in ps[1:]))
            x = self.fresh()
            step = self.gen(ret, env + [(x, ret)], depth - 1)
            return 'let rec %s %s = if p0 <= 0 then %s else (let %s = %s in %s);;' % (
                name, ' '.join(pn), base, x, rec.strip(), step)
        body = self.gen(ret, env, depth)
        self.funs.append((name, ps, ret))
        return 'let %s %s = %s;;' % (name, ' '.join(pn), body)

    def ill_typed(self, depth):
        """A bare expression with exactly one type error of a chosen kind."""
        rng = self.rng
        self.v = 0
        r = rng.random()
        if r < 0.5:
            return '(%s) + (%s);;' % (self.gen(INT, list(self.vals), depth), self.gen(BOOL, list(self.vals), depth))
        if r < 0.7:
            x = self.fresh()
            return '(fun %s -> %s %s) %s;;' % (x, x, x, self.gen(INT, list(self.vals), depth))
        if r < 0.85:
            return '[%s; %s];;' % (self.gen(L(INT), list(self.vals), depth), self.gen(L(BOOL), list(self.vals), depth))
        return 'length (%s :: undefined%d);;' % (self.gen(INT, list(self.vals), depth), rng.randrange(4))


MONAD_PRELUDE = [
    'let ret x s = (x, s);;',
    'let bind m k s = let p = m s in k (fst p) (snd p);;',
    'let get s = (s, s);;',
    'let put x s = ((), x);;',
    'let fmap f m = bind m (fun x -> ret (f x));;',
    'let seq m1 m2 = bind m1 (fun u -> m2);;',
    'let m0 = ret 0;;',
    'let m1 = ret true;;',
    'let m2 = fmap (fun s -> [s]) get;;',
]


class MonadLibrary:
    """Emits monadic definitions m3, m4, ... each built from earlier ones.
    `size` tracks the number of leaves of each action's result type so the
    types stay moderate (at most `cap` leaves)."""

    def __init__(self, rng, cap):
        self.rng = rng
        self.cap = cap
        self.size = [1, 1, 2]

    def next(self):
        rng, sz, cap = self.rng, self.size, self.cap
        k = len(sz)
        i, j = rng.randrange(k), rng.randrange(k)
        r = rng.random()
        if r < 0.35 and sz[i] + sz[j] <= cap:
            sz.append(sz[i] + sz[j])
            return ['let m%d = bind m%d (fun x -> bind m%d (fun y -> ret (x, y)));;' % (k, i, j)]
        if r < 0.5 and sz[i] < cap:
            sz.append(sz[i] + 1)
            return ['let m%d = fmap (fun x -> [x; x]) m%d;;' % (k, i)]
        if r < 0.6:
            sz.append(1)
            return ['let m%d = fmap (fun x -> length [x; x]) m%d;;' % (k, i)]
        if r < 0.7:
            sz.append(sz[j])
            return ['let m%d = seq m%d (bind get (fun s -> seq (put s) m%d));;' % (k, i, j)]
        if r < 0.8:
            sz.append(sz[i])
            return ['let m%d = bind m%d (fun x -> if null [x] then ret x else fmap (fun z -> x) m%d);;' % (k, i, j)]
        if r < 0.9 and sz[i] < cap:
            sz.append(sz[i] + 1)
            return ['let m%d = fmap (fun p -> (p, 1 + length [p])) m%d;;' % (k, i)]
        sz.append(sz[j])
        return ['(m%d 0, m%d true, m%d [()]);;' % (i, j, i), 'let m%d = m%d;;' % (k, j)]


def module_throughput(max_bytes=MAX_BYTES, max_decls=MAX_DECLS):
    rng = random.Random(2024)
    typed = TypedGen(random.Random(3))
    lib = MonadLibrary(random.Random(5), 64)
    lines = list(TYPED_PRELUDE) + list(MONAD_PRELUDE)
    size = sum(len(x) + 1 for x in lines)
    while len(lines) < max_decls - 2:
        r = rng.random()
        if r < 0.03:
            texts = [typed.ill_typed(4)]
        elif r < 0.83:
            texts = [typed.declaration(5)]
            if len(texts[0]) > 3000:
                continue
        else:
            texts = lib.next()
        n = sum(len(x) + 1 for x in texts)
        if size + n > max_bytes - 1000:
            break
        lines.extend(texts)
        size += n
    return '\n'.join(lines) + '\n'


# ---------------------------------------------------------------------------
# 002: long let-in chains, as produced by compilers emitting A-normal form.
# Each binding is one small operation on earlier bindings; a "state" value
# threads through the chain and grows, so generalising and instantiating it
# costs time proportional to its type, and the work per chain is quadratic.
# ---------------------------------------------------------------------------
def anf_chain(rng, n, k):
    """One declaration: `let anfK z = let ... in <result>` with n bindings."""
    out = ['let anf%d z w =' % k]
    out.append('let s0 = (z, w) in')
    nums = ['w0']
    out.append('let w0 = 0 in')
    funs = []
    for i in range(1, n):
        r = rng.random()
        s = 's%d' % (i - 1)
        if r < 0.30:
            # Grow the state by one level.
            out.append('let s%d = (%s, %s) in' % (i, s, rng.choice(nums)))
        elif r < 0.40:
            out.append('let s%d = (%s, [%s; %s]) in' % (i, s, rng.choice(nums), rng.choice(nums)))
        elif r < 0.50:
            out.append('let s%d = (fun q -> (q, %s)) %s in' % (i, rng.choice(nums), s))
        elif r < 0.62:
            v = 'w%d' % i
            a, b = rng.choice(nums), rng.choice(nums)
            op = rng.choice(['+', '-', '*', '/'])
            out.append('let %s = %s %s %s in' % (v, a, op, b))
            out.append('let s%d = %s in' % (i, s))
            nums.append(v)
        elif r < 0.72:
            # A local polymorphic helper, used at two types.
            f = 'h%d' % i
            out.append('let %s x y = (y, x) in' % f)
            out.append('let s%d = snd (%s %s (%s true 1)) in' % (i, f, s, f))
            funs.append(f)
        elif r < 0.80 and funs:
            g = rng.choice(funs)
            out.append('let s%d = fst (%s (%s 0 false) %s) in' % (i, g, g, s))
        elif r < 0.88:
            v = 'w%d' % i
            out.append('let %s = if %s < %s then length [%s] else %s in' % (v, rng.choice(nums), rng.choice(nums), s, rng.choice(nums)))
            out.append('let s%d = %s in' % (i, s))
            nums.append(v)
        else:
            out.append('let rec loop%d n = if n = 0 then %s else loop%d (n - 1) in' % (i, s, i))
            out.append('let s%d = loop%d %s in' % (i, i, rng.choice(nums)))
    last = 's%d' % (n - 1)
    out.append('(length [%s; %s], %s);;' % (last, last, rng.choice(nums)))
    return '\n'.join(out)


def anf_chains(max_bytes=MAX_BYTES):
    rng = random.Random(77)
    decls = []
    size = 0
    k = 0
    while True:
        n = rng.choice([2900, 2900, 2500, 2000, 1500])
        d = anf_chain(rng, n, k)
        if size + len(d) + 1 > max_bytes - 1000:
            break
        decls.append(d)
        size += len(d) + 1
        # Use each chain at a concrete type so the generalised scheme is
        # instantiated.
        u = 'anf%d 1 true;;' % k
        decls.append(u)
        size += len(u) + 1
        k += 1
    return '\n'.join(decls) + '\n'


# ---------------------------------------------------------------------------
# 003: large types. Builds generalised values whose types have up to 2^12
# leaves and thousands of type variables, then uses them the way a program
# would: in lists, through map/fold, compared via unification, projected.
# Most results are small so the work is inference, not printing.
# ---------------------------------------------------------------------------
def shared_tower_uses(rng, n):
    """Uses of the p towers, whose types have 2^a leaves but share one
    subterm per level: instantiation is cheap, so the time goes to unifying
    and comparing the large types rather than to building them."""
    uses = []
    for j in range(n):
        r = rng.random()
        a = rng.choice((10, 11, 12, 12))
        if r < 0.50:
            m = rng.randint(6, 16)
            uses.append('length [%s];;' % '; '.join(['p%d' % a] * m))
        elif r < 0.60:
            uses.append('null (both p%d (fst (p%d, q%d)));;' % (a, a, rng.randint(2, 6)))
        elif r < 0.70:
            uses.append('length (map (fun t -> (fst t, snd t)) [p%d; p%d; snd (pair p%d)]);;' % (a, a, a - 1))
        elif r < 0.80:
            uses.append('fold (fun acc t -> acc + length [t; p%d]) 0 [p%d; p%d];;' % (a, a, a))
        elif r < 0.90:
            uses.append('(fun x -> null [x; p%d; fst (pair p%d)]) p%d;;' % (a, a, a))
        elif r < 0.95:
            # Fails: the two towers have different depths.
            uses.append('[p%d; p%d; p%d];;' % (a, a - 1, a))
        else:
            uses.append('let s%d = fun z -> length [p%d; snd (z, p%d)] + z;;' % (j, a, a))
    return uses


def big_types(extra_uses=0):
    rng = random.Random(4242)
    L = []
    L.append('let pair x = (x, x);;')
    L.append('let swap p = (snd p, fst p);;')
    L.append('let compose f g x = f (g x);;')
    L.append('let q0 = fun x -> x;;')
    for i in range(1, 13):
        L.append('let q%d = (q%d, q%d);;' % (i, i - 1, i - 1))
    L.append('let p0 = fun x -> x;;')
    for i in range(1, 13):
        L.append('let p%d = pair p%d;;' % (i, i - 1))
    L.append('let r0 = fun x -> [x];;')
    for i in range(1, 11):
        L.append('let r%d = (r%d, swap (r%d, q%d));;' % (i, i - 1, i - 1, i - 1))
    L.append('let mk x = (q8, x, p8);;')
    L.append('let both a b = [a; b];;')
    # A mixed stream of uses, mostly with small result types.
    uses = []
    for j in range(1100):
        r = rng.random()
        a = rng.randint(7, 12)
        if r < 0.20:
            m = rng.randint(4, 12)
            uses.append('length [%s];;' % '; '.join(['q%d' % a] * m))
        elif r < 0.35:
            uses.append('null (both q%d (fst (q%d, p%d)));;' % (a, a, a))
        elif r < 0.50:
            uses.append('length (map (fun t -> (fst t, snd t)) [q%d; q%d; snd (pair q%d)]);;' % (a, a, a))
        elif r < 0.60:
            uses.append('fold (fun acc t -> acc + length [t; q%d]) 0 [q%d; q%d];;' % (a, a, a))
        elif r < 0.70:
            b = rng.randint(6, 10)
            uses.append('let u%d = fun z -> length [r%d; r%d; (fst r%d, snd r%d)] + z;;' % (j, b, b, b, b))
        elif r < 0.78:
            uses.append('(fun x -> null [x; p%d; q%d]) q%d;;' % (a, a, a))
        elif r < 0.86:
            # Fails: the two towers have different shapes at the leaves.
            uses.append('[q%d; q%d; q%d];;' % (a, a + 1 if a < 12 else a - 1, a))
        elif r < 0.93:
            uses.append('let v%d = compose fst swap (p%d, q%d);;' % (j, rng.randint(2, 5), rng.randint(2, 5)))
        else:
            uses.append('length [mk 1; mk 2; mk (fst (mk 3))];;')
    L.extend(uses)
    L.extend(shared_tower_uses(random.Random(4343), extra_uses))
    # A few large results are printed as well.
    L.append('q10;;')
    L.append('fun x -> (p9, x, r6);;')
    return '\n'.join(L) + '\n'


CASES = [
    ('module_throughput', module_throughput),
    ('anf_let_chains', anf_chains),
    ('big_types', big_types),
]

# Long tier (../bench-long): the same three programs scaled up. 001 is the
# same module stream continued to 10x the size; 002 has about five times as
# many let chains of the same lengths; 003 keeps the short input's 1100 uses
# and adds 16000 uses of the shared p towers.
LONG_DIR = os.path.join(PROBLEM, 'bench-long')
LONG_MAX_BYTES = 12_000_000
LONG_MAX_DECLS = 60_000
LONG_CASES = [
    ('module_throughput', lambda: module_throughput(LONG_MAX_BYTES, LONG_MAX_DECLS)),
    ('anf_let_chains', lambda: anf_chains(6_000_000)),
    ('big_types', lambda: big_types(16000)),
]


def main():
    want_expected = '--no-expected' not in sys.argv
    long = '--long' in sys.argv
    out_dir = LONG_DIR if long else HERE
    max_bytes, max_decls = (LONG_MAX_BYTES, LONG_MAX_DECLS) if long else (MAX_BYTES, MAX_DECLS)
    os.makedirs(out_dir, exist_ok=True)
    only = [a for a in sys.argv[1:] if not a.startswith('--')]
    for idx, (name, fn) in enumerate(LONG_CASES if long else CASES, 1):
        if only and not any(('%03d_%s' % (idx, name)).startswith(o) for o in only):
            continue
        src = fn()
        assert len(src.encode()) <= max_bytes, name
        assert src.count(';;') <= max_decls, name
        base = os.path.join(out_dir, '%03d_%s' % (idx, name))
        with open(base + '.in', 'w') as f:
            f.write(src)
        line = '%-24s %5d decls %8d bytes in' % (name, src.count(';;'), len(src))
        if want_expected:
            p = subprocess.run([sys.executable, REF], input=src.encode(), capture_output=True)
            if p.returncode != 0:
                sys.exit('reference failed on %s:\n%s' % (name, p.stderr.decode()))
            with open(base + '.out', 'wb') as f:
                f.write(p.stdout)
            line += ' %8d bytes out' % len(p.stdout)
        print(line, flush=True)


if __name__ == '__main__':
    main()
