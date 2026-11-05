#!/usr/bin/env python3
"""Generates tests/*.in and tests/*.out for the `typeinfer` problem.

Every test is either an embedded literal program or the output of a seeded
generator, so re-running this script reproduces the suite exactly. Expected
outputs come from reference/main.py and every declaration of every test is
cross-checked against OCaml (see oracle.py for how OCaml is made to follow
the spec's rules); the script aborts on any disagreement.

The one known way OCaml can legitimately differ is the error kind of a
declaration that contains several errors, because OCaml propagates expected
types downwards instead of unifying after inferring each sub-expression.
Hand-written tests avoid such declarations, and the random generators drop
any declaration on which the two disagree, so the suite only contains
declarations whose error kind does not depend on that choice.
"""
import os
import random
import shutil
import subprocess
import sys
import threading

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.join(HERE, 'tests')
REF = os.path.join(HERE, 'reference', 'main.py')
sys.path.insert(0, HERE)
import oracle  # noqa: E402

cases = []


def add(name, src):
    cases.append((name, src))


# ---------------------------------------------------------------------------
# Hand-written programs
# ---------------------------------------------------------------------------
add('empty_program', '')

add('literals', '''1;;
0;;
123456789012345678901234567890;;
true;;
false;;
();;
[];;
''')

add('builtins', '''not;;
fst;;
snd;;
hd;;
tl;;
null;;
map;;
fold;;
length;;
''')

add('identity_const_compose', '''let id = fun x -> x;;
let const x y = x;;
let compose f g x = f (g x);;
let flip f x y = f y x;;
let apply f x = f x;;
let twice f x = f (f x);;
id;;
id 1;;
id true;;
id id;;
const 1 true;;
compose (fun x -> x + 1) (fun b -> if b then 1 else 0);;
flip const;;
twice (fun x -> x * 2) 3;;
twice;;
compose compose;;
compose id id;;
apply id;;
''')

add('operators', '''1 + 2;;
1 + 2 * 3 - 4 / 5;;
fun x y -> x * y + 1;;
1 < 2;;
fun a b -> a <= b;;
fun a b -> a >= b && a > b || a = b;;
not (1 = 2);;
true && false || true;;
fun p q -> p && not q;;
fun f x -> f x + 1;;
fun f g x -> f x * g x;;
fun x -> if x < 0 then 0 - x else x;;
''')

add('lists_and_cons', '''[1; 2; 3];;
[true];;
[[]];;
[[1]; []];;
1 :: [];;
1 :: 2 :: [];;
fun x -> x :: [];;
fun x l -> x :: l;;
fun l -> hd l :: tl l;;
[fun x -> x];;
[fun x -> x; fun y -> y + 1];;
fun x -> [x; x];;
fun x y -> [x; y];;
[[]] :: [];;
fun l -> if null l then 0 else length l;;
[(1, true); (2, false)];;
[] :: [] :: [];;
''')

add('tuples_and_parens', '''(1, true);;
(1, true, ());;
((1, 2), 3);;
(1, (2, 3));;
fun x -> (x, x);;
fun x y -> (x, y);;
fun x y -> (y, x);;
fst (1, true);;
snd (1, true);;
fun p -> (snd p, fst p);;
(fun x -> x, 1);;
((fun x -> x), (fun y -> y));;
[(fun x -> x, 1)];;
fun x -> [(x, x)];;
(fun x -> (x, [x]), (fun y -> y));;
fun f -> (f, f 1);;
fun f -> f (1, 2);;
fun f -> (fun x -> f x, fun y -> f y);;
fun x -> ((x, x), (x, x));;
((1, 2), (true, false), ((), []));;
fun f -> ((f, 1), [f]);;
''')

add('let_polymorphism', '''let id = fun x -> x;;
(id 1, id true);;
(let f = fun x -> x in (f 1, f true));;
(fun f -> (f 1, f true)) (fun x -> x);;
fun f -> (f 1, f true);;
fun f -> (f 1, f 2);;
fun g -> let f = fun x -> g x in (f 1, f true);;
fun g -> let f = fun x -> x in (f 1, f true, g);;
let pair = fun x -> (x, x);;
let p1 = pair id;;
fun x -> let y = x in (y, y);;
fun x -> let f = fun y -> (x, y) in (f 1, f true);;
let g = id id;;
g;;
(g 1, g true);;
(let h = fun x -> id x in (h 1, h true));;
let k = compose;;
let compose f g x = f (g x);;
let k = compose id id;;
(k 1, k true);;
''')

add('occurs_check', '''fun x -> x x;;
fun f -> f f;;
let rec f x = f;;
let rec g x = (g, x);;
fun x -> [x; [x]];;
fun x -> (x, x) :: x;;
fun f x -> f (f) x;;
(let omega = fun x -> x x in omega);;
fun x -> x :: x;;
fun f -> f (fun x -> f);;
fun x -> (x, x x);;
let rec loop x = loop;;
fun x -> let y = x in y y;;
(let f x = x x in f);;
fun f -> (fun x -> f (x x)) (fun x -> f (x x));;
''')

add('unbound_variables', '''x;;
fun x -> y;;
let a = b;;
a;;
let a = 1;;
a;;
let a = zzz;;
a;;
let f x = g x;;
f;;
let g x = x;;
let f x = g x;;
f;;
fun x -> let y = x in z;;
let x = x;;
let rec f x = f y;;
[x; 1];;
(1, w);;
(let t = 5 in t + u);;
''')

add('unify_errors', '''1 + true;;
if 1 then 2 else 3;;
if true then 1 else false;;
1 1;;
(fun x -> x + 1) true;;
[1; true];;
1 :: [true];;
1 :: 2;;
fst 1;;
hd 1;;
length (1, 2);;
fun x -> x + 1 && x;;
map (fun x -> x + 1) [true];;
fold (fun a x -> a + x) 0 [true];;
(fun f -> f 1) (fun x -> x + 1) + true;;
(let f x = x + 1 in f true);;
(let x = 1 in x 2);;
(1, 2) = (1, 2);;
true < false;;
[] + 1;;
() = ();;
not 1;;
if true then (1, 2) else (1, 2, 3);;
''')

add('let_rec', '''let rec len l = if null l then 0 else 1 + len (tl l);;
let rec sum l = if null l then 0 else hd l + sum (tl l);;
let rec mymap f l = if null l then [] else f (hd l) :: mymap f (tl l);;
let rec fix f = f (fix f);;
let rec forever x = forever x;;
let rec fact n = if n = 0 then 1 else n * fact (n - 1);;
let rec app l1 l2 = if null l1 then l2 else hd l1 :: app (tl l1) l2;;
let rec rev l = if null l then [] else app (rev (tl l)) [hd l];;
let rec f x = f (f x);;
let rec g x = g x + 1;;
let rec h x y = if x then y else h (not x) y;;
let rec k x = k;;
let rec bad x = bad 1 + bad true;;
let rec ok x = let y = ok x in y;;
(let rec poly x = x in (poly 1, poly true));;
fun z -> let rec self x = self x in (self 1, self true);;
(let rec f x = 1 in (f 1, f true));;
let rec count n acc = if n = 0 then acc else count (n - 1) (acc + 1);;
let rec zip a b = if null a then [] else (hd a, hd b) :: zip (tl a) (tl b);;
zip [1] [true];;
let rec iter f n x = if n = 0 then x else iter f (n - 1) (f x);;
(let rec bad x = bad 1 + bad true in bad);;
fun z -> let rec bad x = if bad true then z else 0 in bad;;
(let rec bad x = (bad 1 + 1, bad true) in bad);;
fun z -> let rec ok x = z in (ok 1, ok true);;
''')

add('church_numerals', '''let zero = fun f x -> x;;
let one = fun f x -> f x;;
let two = fun f x -> f (f x);;
let succ n = fun f x -> f (n f x);;
let add m n = fun f x -> m f (n f x);;
let mul m n = fun f -> m (n f);;
let exp m n = n m;;
let three = succ two;;
let four = add two two;;
let six = mul two three;;
let tonat n = n (fun x -> x + 1) 0;;
tonat three;;
tonat (exp two three);;
let ctrue = fun a b -> a;;
let cfalse = fun a b -> b;;
let cif c t e = c t e;;
cif ctrue 1 2;;
let cand p q = p q p;;
let cor p q = p p q;;
let cnot p = p cfalse ctrue;;
let iszero n = n (fun x -> cfalse) ctrue;;
let pair a b f = f a b;;
let pfst p = p ctrue;;
let psnd p = p cfalse;;
pfst (pair 1 true);;
psnd (pair 1 true);;
''')

add('map_fold', '''let sum = fold (fun a x -> a + x) 0;;
let rev l = fold (fun acc x -> x :: acc) [] l;;
let len l = fold (fun n x -> n + 1) 0 l;;
let mymap f l = fold (fun acc x -> f x :: acc) [] l;;
let all l = fold (fun a b -> a && b) true l;;
let count p l = fold (fun n x -> if p x then n + 1 else n) 0 l;;
map (fun x -> (x, x));;
map fst;;
map (map (fun x -> x + 1));;
map (fun f -> f 1);;
map (fun f -> f 1) [fun x -> x; fun x -> x * 2];;
fold (fun acc f -> f acc) 0;;
fold (fun acc f -> f acc) 0 [fun x -> x + 1];;
fold (fun a b -> a) ;;
fold (fun a b -> b);;
fun l -> map hd l;;
fun l -> map (fun p -> (snd p, fst p)) l;;
fun l -> fold (fun acc x -> acc) (hd l) (tl l);;
let compose f g x = f (g x);;
compose (map fst) (map (fun x -> (x, x)));;
let flatten l = fold app [] l;;
let rec app a b = if null a then b else hd a :: app (tl a) b;;
let flatten l = fold app [] l;;
flatten;;
''')

add('sugar_and_nesting', '''let f x y z = (x, y, z);;
let g = fun x -> fun y -> (x, y);;
let h x = fun y -> (x, y);;
let k = fun x y -> (x, y);;
(let x = 1 in x);;
(let x = 1 in let y = true in (x, y));;
(let f x = x in f);;
(let rec f x = f x in f);;
let a = let b = let c = 1 in c in b;;
let outer = let inner x = x in inner inner;;
let nest = fun a -> let b = fun c -> (a, c) in let d = b 1 in let e = b true in (d, e);;
fun x -> let x = (x, x) in let x = (x, x) in x;;
let shadow x = let x = true in x;;
let shadow2 = fun x -> fun x -> x;;
(let z = 3 in let z = z + 1 in z);;
''')

add('shadowing_and_lexing', '''let map = 3;;
map;;
let fst x = x;;
fst 1;;
let hd = true;;
hd;;
let not = fun x -> x + 1;;
not 1;;
let letx = 1;;
let inx = 2;;
let funny = 3;;
let iffy = 4;;
let thenx = 5;;
let recx = 6;;
let truex = 7;;
let x_1 = 8;;
let x1 = 9;;
let xY = 10;;
let a_B_c9 = 11;;
(letx, inx, funny, iffy, thenx, recx, truex, x_1, x1, xY, a_B_c9);;
let ab=fun a b->(a,b);;
ab;;
fun x->x;;
if true then 1 else 2;;
[1;2;3];;
1+2*3;;
fun f->f(1)(2);;
''')

add('error_continuation', '''let a = 1;;
let a = a + true;;
a;;
let b = 1 :: a :: [];;
let c = undefined;;
let d = fun x -> x x;;
let e = (a, b);;
c;;
d;;
e;;
let f = fun x -> if x then x + 1 else 0;;
let g = 42;;
let g = g 1;;
g;;
let h = fun x -> (x, g);;
h;;
let rec i x = i x x;;
let rec i x = i;;
i;;
let rec i x = x;;
i;;
missing;;
(fun x -> x) (fun y -> z);;
fun x -> x x;;
1 + 1;;
''')

# Every declaration here has two problems; the spec's left-to-right
# infer-then-unify order decides which kind is reported. OCaml agrees on all
# of them (gen_tests aborts otherwise).
add('error_kind_ordering', '''fun x -> if true then (x, 0) else ([x], true);;
fun x -> if true then ([x], true) else (x, 0);;
fun x -> if true then (0, x) else (true, [x]);;
fun x -> [(x, 0); ([x], true)];;
fun x -> (x, 0) :: [([x], true)];;
fun x -> if true then fun f -> f x 0 else fun g -> g [x] true;;
fun x y -> if true then (fun a -> a x 0) else (fun b -> b [x] y);;
fun x -> if true then (x, 0, 0) else (0, [x], true);;
fun x -> if true then (0, x, 0) else (true, [x], 0);;
fun x -> if true then ((x, 0), true) else (([x], true), 0);;
fun x -> if true then (fun y -> y) x 0 else 1 [x];;
true + undefined;;
undefined + true;;
1 + true + undefined;;
if 1 then undefined else 2;;
if true then 1 else undefined;;
if 1 then 2 else 3 4;;
(1 1) undefined;;
undefined (1 1);;
(fun f -> f) undefined 1;;
true :: undefined;;
undefined :: true;;
1 :: 2 :: undefined;;
[1; true; undefined];;
[undefined; 1; true];;
(1 + true, undefined);;
(undefined, 1 + true);;
true && undefined;;
(let x = 1 + true in undefined);;
(let x = undefined in 1 + true);;
(let rec f x = f in undefined);;
(let rec f x = f x in undefined);;
fun x -> (fun y -> y y) undefined;;
fun x -> x x undefined;;
fun x -> undefined (x x);;
fun x -> (fun y -> y) x x;;
''')

add('many_type_variables', '''fun a b c d e f g h i j k l m n o p q r s t u v w x y z aa bb cc dd ee -> (ee, dd, cc, bb, aa, z, y, x, w, v, u, t, s, r, q, p, o, n, m, l, k, j, i, h, g, f, e, d, c, b, a);;
fun a b c d e f g h i j k l m n o p q r s t u v w x y z aa bb cc dd ee -> (a, b, c, d, e, f, g, h, i, j, k, l, m, n, o, p, q, r, s, t, u, v, w, x, y, z, aa, bb, cc, dd, ee);;
fun a b c d e f g h i j k l m n o p q r s t u v w x y z aa bb cc dd ee -> [a; b; c; d; e; f; g; h; i; j; k; l; m; n; o; p; q; r; s; t; u; v; w; x; y; z; aa; bb; cc; dd; ee];;
let big a b c d e f g h i j k l m n o p q r s t u v w x y z aa bb cc dd ee ff gg hh ii jj kk ll mm nn oo pp qq rr ss tt uu vv ww xx yy zz aaa bbb ccc = (a, (b, (c, (d, (e, (f, (g, (h, (i, (j, (k, (l, (m, (n, (o, (p, (q, (r, (s, (t, (u, (v, (w, (x, (y, (z, (aa, (bb, (cc, (dd, (ee, (ff, (gg, (hh, (ii, (jj, (kk, (ll, (mm, (nn, (oo, (pp, (qq, (rr, (ss, (tt, (uu, (vv, (ww, (xx, (yy, (zz, (aaa, (bbb, ccc))))))))))))))))))))))))))))))))))))))))))))))))))))));;
big;;
''')

add('pair_chain', '''let pair x = (x, x);;
let id = fun x -> x;;
let p0 = pair id;;
let p1 = pair p0;;
let p2 = pair p1;;
let p3 = pair p2;;
let p4 = pair p3;;
p4;;
(p0, p1);;
let q x = (x, [x]);;
q (q (q (q (q 1))));;
q (q (q id));;
let dup x = fun y -> (x, y);;
dup (dup (dup id));;
''')

add('formatting_and_whitespace', '''let   a   =   1   ;;
let b
  =
  fun x
    ->
      x
;;
let c = (
  1,
  true
);;
	let d = [ 1 ;
	2 ;
	3 ] ;;
let e=fun f g->f g;;let f=e;;f;;
(1,2);;((1),(2));;
let g = if true
        then fun x -> x
        else fun y -> y
;;
g;;

''')

# ---------------------------------------------------------------------------
# Random programs
# ---------------------------------------------------------------------------
NAMES = ['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'k', 'l', 'm', 'n', 'p', 'q',
         'r', 's', 't', 'u', 'v', 'w', 'x', 'y', 'z', 'acc', 'lst', 'fn', 'x1', 'x2']
BUILTINS = ['not', 'fst', 'snd', 'hd', 'tl', 'null', 'map', 'fold', 'length']
BINOPS = ['+', '-', '*', '/', '=', '<', '>', '<=', '>=', '&&', '||']


class RandomProgram:
    """Produces random declarations. Right-hand sides of `let` are syntactic
    values (so OCaml's value restriction never applies) and errors appear at
    a controllable rate through unbound names and ill-typed operands."""

    def __init__(self, rng, max_depth, err_rate):
        self.rng = rng
        self.max_depth = max_depth
        self.err_rate = err_rate
        self.toplevel = []

    def fresh(self, scope):
        return self.rng.choice(NAMES)

    def var(self, scope):
        r = self.rng.random()
        if scope and r < 0.7:
            return ('var', self.rng.choice(scope))
        if self.toplevel and r < 0.85:
            return ('var', self.rng.choice(self.toplevel))
        if r < 0.85 + self.err_rate and self.rng.random() < 0.5:
            return ('var', 'undefined' + str(self.rng.randint(0, 3)))
        return ('var', self.rng.choice(BUILTINS))

    def value(self, depth, scope):
        """A syntactic value: literal, variable, fun, or tuple/list/let of values."""
        r = self.rng.random()
        if depth >= self.max_depth or r < 0.3:
            k = self.rng.random()
            if k < 0.3:
                return ('int',)
            if k < 0.45:
                return ('bool',)
            if k < 0.5:
                return ('unit',)
            if k < 0.55:
                return ('list', [])
            return self.var(scope)
        if r < 0.65:
            return self.fun(depth, scope)
        if r < 0.8:
            n = self.rng.randint(2, 3)
            return ('tuple', [self.value(depth + 1, scope) for _ in range(n)])
        if r < 0.9:
            n = self.rng.randint(0, 3)
            return ('list', [self.value(depth + 1, scope) for _ in range(n)])
        name = self.fresh(scope)
        return ('let', name, self.value(depth + 1, scope), self.value(depth + 1, scope + [name]))

    def fun(self, depth, scope):
        n = self.rng.randint(1, 3)
        ps = []
        for _ in range(n):
            p = self.fresh(scope)
            while p in ps:
                p = self.fresh(scope)
            ps.append(p)
        return ('fun', ps, self.expr(depth + 1, scope + ps))

    def expr(self, depth, scope):
        r = self.rng.random()
        if depth >= self.max_depth or r < 0.2:
            return self.value(depth, scope)
        if r < 0.45:
            f = self.var(scope) if self.rng.random() < 0.7 else self.expr(depth + 1, scope)
            e = ('app', f, self.expr(depth + 1, scope))
            while self.rng.random() < 0.4:
                e = ('app', e, self.expr(depth + 1, scope))
            return e
        if r < 0.55:
            return self.fun(depth, scope)
        if r < 0.65:
            name = self.fresh(scope)
            return ('let', name, self.value(depth + 1, scope), self.expr(depth + 1, scope + [name]))
        if r < 0.7:
            name = self.fresh(scope)
            ps = [self.fresh(scope)]
            body = self.expr(depth + 1, scope + [name] + ps)
            return ('letrec', name, ('fun', ps, body), self.expr(depth + 1, scope + [name]))
        if r < 0.78:
            return ('if', self.expr(depth + 1, scope), self.expr(depth + 1, scope), self.expr(depth + 1, scope))
        if r < 0.85:
            return ('tuple', [self.expr(depth + 1, scope) for _ in range(self.rng.randint(2, 3))])
        if r < 0.9:
            return ('list', [self.expr(depth + 1, scope) for _ in range(self.rng.randint(0, 3))])
        if r < 0.93:
            return ('cons', self.expr(depth + 1, scope), self.expr(depth + 1, scope))
        op = self.rng.choice(BINOPS)
        return ('binop', op, self.operand(op, depth + 1, scope), self.operand(op, depth + 1, scope))

    def operand(self, op, depth, scope):
        """Operands are biased towards the right type so that most binary
        operations are well typed; the error rate controls the rest."""
        if self.rng.random() < self.err_rate:
            return self.expr(depth, scope)
        if op in ('&&', '||'):
            r = self.rng.random()
            if r < 0.3:
                return ('bool',)
            if r < 0.6:
                return ('binop', self.rng.choice(['<', '=', '>=']), self.operand('<', depth + 1, scope), self.operand('<', depth + 1, scope))
            return ('app', ('var', 'not'), self.operand('&&', depth + 1, scope))
        r = self.rng.random()
        if r < 0.4:
            return ('int',)
        if r < 0.6:
            return ('app', ('var', 'length'), self.expr(depth + 1, scope))
        if r < 0.8 and scope:
            return ('var', self.rng.choice(scope))
        return ('binop', self.rng.choice(['+', '-', '*']), self.operand('+', depth + 1, scope), self.operand('+', depth + 1, scope))

    def declaration(self):
        r = self.rng.random()
        if r < 0.5:
            name = self.fresh([])
            d = ('let', name, self.value(0, []))
        elif r < 0.65:
            name = self.fresh([])
            ps = [self.fresh([])]
            d = ('letrec', name, ('fun', ps, self.expr(1, [name] + ps)))
        else:
            d = ('expr', self.expr(0, []))
        return d


# Pretty printer that emits the spec's concrete syntax with just enough
# parentheses, so generated programs exercise the precedence rules.
PREC = {'||': 1, '&&': 2, '=': 3, '<': 3, '>': 3, '<=': 3, '>=': 3, '+': 5, '-': 5, '*': 6, '/': 6}


def pp(node, rng):
    k = node[0]
    if k == 'int':
        return str(rng.choice([0, 1, 2, 7, 42, 1000]))
    if k == 'bool':
        return rng.choice(['true', 'false'])
    if k == 'unit':
        return '()'
    if k == 'var':
        return node[1]
    if k == 'fun':
        return 'fun %s -> %s' % (' '.join(node[1]), pp(node[2], rng))
    if k == 'app':
        return '%s %s' % (pp_prec(node[1], rng, 7), pp_prec(node[2], rng, 8))
    if k == 'let':
        rhs = node[2]
        if rhs[0] == 'fun' and rng.random() < 0.5:
            return 'let %s %s = %s in %s' % (node[1], ' '.join(rhs[1]), pp(rhs[2], rng), pp(node[3], rng))
        return 'let %s = %s in %s' % (node[1], pp(rhs, rng), pp(node[3], rng))
    if k == 'letrec':
        rhs = node[2]
        return 'let rec %s %s = %s in %s' % (node[1], ' '.join(rhs[1]), pp(rhs[2], rng), pp(node[3], rng))
    if k == 'if':
        return 'if %s then %s else %s' % (pp(node[1], rng), pp(node[2], rng), pp(node[3], rng))
    if k == 'tuple':
        return '(' + ', '.join(pp(x, rng) for x in node[1]) + ')'
    if k == 'list':
        return '[' + '; '.join(pp(x, rng) for x in node[1]) + ']'
    if k == 'cons':
        return '%s :: %s' % (pp_prec(node[1], rng, 5), pp_prec(node[2], rng, 4))
    if k == 'binop':
        p = PREC[node[1]]
        # Comparisons are non-associative, arithmetic and boolean operators
        # are left-associative.
        left = pp_prec(node[2], rng, p if node[1] not in ('=', '<', '>', '<=', '>=') else p + 1)
        right = pp_prec(node[3], rng, p + 1)
        return '%s %s %s' % (left, node[1], right)
    raise AssertionError(k)


def node_prec(node):
    k = node[0]
    if k in ('fun', 'let', 'letrec', 'if'):
        return 0
    if k == 'binop':
        return PREC[node[1]]
    if k == 'cons':
        return 4
    if k == 'app':
        return 7
    return 9


def pp_prec(node, rng, minp):
    s = pp(node, rng)
    if node_prec(node) < minp or rng.random() < 0.05:
        return '(' + s + ')'
    return s


def pp_decl(d, rng):
    if d[0] == 'expr':
        # A bare expression that starts with `let` must be parenthesised,
        # since a declaration starting with `let` is always a binding.
        text = pp(d[1], rng)
        if d[1][0] in ('let', 'letrec'):
            text = '(' + text + ')'
        return text + ';;'
    if d[0] == 'let':
        rhs = d[2]
        if rhs[0] == 'fun' and rng.random() < 0.6:
            return 'let %s %s = %s;;' % (d[1], ' '.join(rhs[1]), pp(rhs[2], rng))
        return 'let %s = %s;;' % (d[1], pp(rhs, rng))
    rhs = d[2]
    return 'let rec %s %s = %s;;' % (d[1], ' '.join(rhs[1]), pp(rhs[2], rng))


def random_program(seed, count, max_depth, err_rate, only_ok=False):
    """Builds a program of `count` declarations. Candidate declarations are
    generated in bulk; those whose error kind is order-sensitive (reference
    and OCaml disagree) are dropped, as are all failing ones when only_ok is
    set. Dropping a failing declaration changes nothing else, since a failed
    declaration binds no name."""
    rng = random.Random(seed)
    gen = RandomProgram(rng, max_depth, err_rate)
    lines = []
    while len(lines) < count:
        batch = []
        for _ in range(count - len(lines) + 10):
            d = gen.declaration()
            batch.append(pp_decl(d, rng))
            if d[0] != 'expr':
                gen.toplevel.append(d[1])
        src = '\n'.join(lines + batch) + '\n'
        mine = oracle.spec_results(src)
        theirs = oracle.run_ocaml(src)
        for text, a, b in zip(batch, mine[len(lines):], theirs[len(lines):]):
            if a[0] == 'ok' and a != b:
                sys.exit('reference and ocaml disagree on a well-typed declaration:\n%s\n%r %r' % (text, a, b))
            if a[0] == 'error' and (only_ok or a != b):
                continue
            lines.append(text)
        lines = lines[:count]
    return '\n'.join(lines) + '\n'


add('random_small_1', random_program(1, 30, 3, 0.15))
add('random_small_2', random_program(2, 30, 3, 0.15))
add('random_small_3', random_program(3, 40, 4, 0.1))
add('random_medium_1', random_program(4, 150, 4, 0.1))
add('random_medium_2', random_program(5, 150, 5, 0.12))
add('random_welltyped_1', random_program(6, 100, 5, 0.05, only_ok=True))
add('random_welltyped_2', random_program(7, 200, 4, 0.05, only_ok=True))
add('random_errors_heavy', random_program(8, 120, 4, 0.35))

# ---------------------------------------------------------------------------
# Stress programs
# ---------------------------------------------------------------------------


def long_let_chain(n):
    parts = ['fun z ->']
    parts.append('let a0 = z in')
    for i in range(1, n):
        parts.append('let a%d = (a%d, %d) in' % (i, i - 1, i))
    parts.append('a%d;;' % (n - 1))
    body = '\n'.join(parts)
    # A second chain where each binding is polymorphic and used at two types.
    parts = ['(let id0 = fun x -> x in']
    for i in range(1, n):
        parts.append('let id%d = fun x -> id%d x in' % (i, i - 1))
    parts.append('(id%d 1, id%d true, id%d));;' % (n - 1, n - 1, n - 1))
    return body + '\n' + '\n'.join(parts) + '\n'


add('stress_let_chain', long_let_chain(3000))


def many_declarations(n):
    rng = random.Random(100)
    lines = ['let f0 x = x;;', 'let g0 x = (x, x);;']
    for i in range(1, n):
        r = rng.random()
        if r < 0.3:
            lines.append('let f%d x = f%d (f%d x);;' % (i, rng.randrange(i), rng.randrange(i)))
        elif r < 0.5:
            lines.append('let g%d x = g%d (f%d x);;' % (i, rng.randrange(i), rng.randrange(i)))
        elif r < 0.7:
            lines.append('let f%d = fun x y -> (f%d x, f%d y);;' % (i, rng.randrange(i), rng.randrange(i)))
        elif r < 0.8:
            lines.append('let g%d x = if x then f%d 1 else f%d 2;;' % (i, rng.randrange(i), rng.randrange(i)))
        elif r < 0.9:
            lines.append('f%d;;' % rng.randrange(i))
            lines.append('let f%d x = x;;' % i)
        else:
            lines.append('let g%d = g%d;;' % (i, rng.randrange(i)))
    return '\n'.join(lines) + '\n'


add('stress_many_declarations', many_declarations(5000))

add('stress_big_list', '[' + '; '.join(str(i) for i in range(100000)) + '];;\n'
    + ' :: '.join(str(i) for i in range(2000)) + ' :: [];;\n'
    + 'fun x -> [' + '; '.join(['x'] * 50000) + '];;\n'
    + '[' + '; '.join(['fun x -> x'] * 20000) + '];;\n')


def pair_tower(n):
    """Two towers of generalised pairs. `pair p_i` instantiates p_i once, so
    p_n has 2^n leaves but a single type variable; (q_i, q_i) instantiates
    q_i twice, so q_n has 2^n distinct type variables."""
    lines = ['let pair x = (x, x);;', 'let p0 = fun x -> x;;']
    for i in range(1, n + 1):
        lines.append('let p%d = pair p%d;;' % (i, i - 1))
    lines.append('p%d;;' % n)
    lines.append('let q0 = fun x -> x;;')
    for i in range(1, n + 1):
        lines.append('let q%d = (q%d, q%d);;' % (i, i - 1, i - 1))
    lines.append('q%d;;' % n)
    lines.append('fun x -> (q%d, x, q%d);;' % (n, n))
    return '\n'.join(lines) + '\n'


add('stress_pair_tower', pair_tower(12))

add('stress_thousand_parameters',
    'fun ' + ' '.join('v%d' % i for i in range(1000)) + ' -> (' + ', '.join('v%d' % i for i in range(1000)) + ');;\n'
    + 'fun ' + ' '.join('v%d' % i for i in range(1000)) + ' -> (' + ', '.join('v%d' % i for i in reversed(range(1000))) + ');;\n'
    + 'fun ' + ' '.join('v%d' % i for i in range(1000)) + ' -> [' + '; '.join('v%d' % i for i in range(1000)) + '];;\n')

add('stress_deep_nesting',
    '(' * 3000 + '1' + ')' * 3000 + ';;\n'
    + 'fun x -> ' + '(x, ' * 2000 + 'x' + ')' * 2000 + ';;\n'
    + 'fun x -> ' + '[' * 2000 + 'x' + ']' * 2000 + ';;\n'
    + ''.join('fun x%d -> ' % i for i in range(2000)) + '(x0, x1999);;\n'
    + 'fun f -> ' + 'f (' * 2000 + '1' + ')' * 2000 + ';;\n'
    + ''.join('if true then %d else ' % i for i in range(2000)) + '0;;\n')

add('stress_application_chain',
    '(let f = fun a b -> a in\nf ' + ' '.join(str(i) for i in range(5000)) + ');;\n'
    + 'fun f -> f ' + ' '.join(['1'] * 5000) + ';;\n'
    + '(let g = fun x y -> (x, y) in\n' + 'g (' * 1500 + '1' + ', 2)' * 1500 + ');;\n')


def instantiation_heavy(n):
    lines = ['let big a b c d e f g h = ((a, b), (c, d), ((e, f), (g, h)), [a; b], (fun x -> (x, c)), (fun y -> (y, d)));;']
    parts = ['fun z -> [']
    parts.append('; '.join('big' if i % 2 else 'big z' for i in range(n)))
    parts.append('];;')
    lines.append(''.join(parts))
    lines.append('fun z -> (' + ', '.join('big z' for _ in range(2000)) + ');;')
    return '\n'.join(lines) + '\n'


add('stress_instantiation', instantiation_heavy(20000))

add('random_large_1', random_program(9, 800, 5, 0.1))
add('random_large_2', random_program(10, 600, 6, 0.12))
add('random_large_welltyped', random_program(11, 700, 6, 0.05, only_ok=True))


# ---------------------------------------------------------------------------
# Write, run the reference, cross-check with OCaml
# ---------------------------------------------------------------------------
def main():
    if shutil.which('ocamlc') is None:
        sys.exit('ocamlc is required to cross-check expected outputs')
    if os.path.isdir(TESTS):
        shutil.rmtree(TESTS)
    os.makedirs(TESTS)
    for idx, (name, src) in enumerate(cases, 1):
        base = os.path.join(TESTS, '%03d_%s' % (idx, name))
        with open(base + '.in', 'w') as f:
            f.write(src)
        p = subprocess.run([sys.executable, REF], input=src.encode(), capture_output=True)
        if p.returncode != 0:
            sys.exit('reference failed on %s:\n%s' % (name, p.stderr.decode()))
        out = p.stdout.decode()
        with open(base + '.out', 'w') as f:
            f.write(out)
        mine = oracle.parse_output(out)
        theirs = oracle.run_ocaml(src)
        if len(theirs) != len(mine):
            sys.exit('%s: ocaml produced %d results for %d declarations' % (name, len(theirs), len(mine)))
        for i, (a, b) in enumerate(zip(mine, theirs)):
            if a != b:
                sys.exit('%s: declaration %d mismatch: reference %r ocaml %r' % (name, i, a, b))
        print('%-32s %6d decls, %7d bytes in, %7d bytes out' % (name, len(mine), len(src), len(out)))
    print('%d tests written' % len(cases))


if __name__ == '__main__':
    # The oracle re-parses deeply nested programs in-process, so it needs the
    # same deep stack as the reference.
    sys.setrecursionlimit(1_000_000)
    threading.stack_size(1024 * 1024 * 1024)
    t = threading.Thread(target=main)
    t.start()
    t.join()
