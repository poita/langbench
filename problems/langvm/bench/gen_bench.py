#!/usr/bin/env python3
"""Generates the langvm performance benchmark inputs and their expected outputs.

Run from anywhere: python3 problems/langvm/bench/gen_bench.py
Every input is deterministic (fixed seeds or fixed source).  Expected outputs
come from the Python reference (reference/main.py); pass --no-expected to
write only the inputs.
"""

import os
import random
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PROBLEM = os.path.dirname(HERE)
sys.path.insert(0, PROBLEM)

import gen_tests as g  # noqa: E402

STDIN_LIMIT = 2000000

# A seven-module application: a discrete-event shop simulation over a generic
# binary heap, a tokeniser and word-frequency pass over generated text, a
# persistent binary search tree built from a sum type, and dense Float matrix
# products.  It touches calls, closures, trait methods, matching, maps, lists,
# strings, sortBy and float formatting in realistic proportions.
MIXED = r'''@module main
use rng;
use pq;
use shop;
use text;
use tree;
use mat;

fn main() {
    print("== shop simulation ==");
    shop::simulate(100000, 41);
    print("== text statistics ==");
    text::run(100000, 7);
    print("== search tree ==");
    tree::run(50000, 99);
    print("== matrices ==");
    mat::run(80, 3);
}
@module rng
pub struct Rng { s: [Int] }

pub fn new(seed: Int) -> Rng { Rng.{ s: [seed * 2654435761 + 1] } }

pub fn next(r: Rng) -> Int {
    let x = r.s[0] * 6364136223846793005 + 1442695040888963407;
    r.s[0] = x;
    (x >> 33) & 0x7fff_ffff
}

pub fn below(r: Rng, n: Int) -> Int { next(r) % n }

pub fn unit(r: Rng) -> Float { toFloat(next(r)) / 2147483648.0 }
@module pq
pub struct Heap<T> { items: [T], less: fn(T, T) -> Bool }

pub fn new<T>(less: fn(T, T) -> Bool) -> Heap<T> { Heap.{ items: listNew(), less: less } }

pub fn size<T>(h: Heap<T>) -> Int { listLen(h.items) }

pub fn add<T>(h: Heap<T>, x: T) {
    let xs = h.items;
    let lt = h.less;
    push(xs, x);
    var i = listLen(xs) - 1;
    while i > 0 {
        let p = (i - 1) / 2;
        if lt(xs[i], xs[p]) {
            let t = xs[i];
            xs[i] = xs[p];
            xs[p] = t;
            i = p;
        } else {
            break;
        }
    }
}

pub fn take<T>(h: Heap<T>) -> T {
    let xs = h.items;
    let top = xs[0];
    let last = pop(xs);
    let n = listLen(xs);
    if n > 0 {
        xs[0] = last;
        let lt = h.less;
        var i = 0;
        while true {
            let l = 2 * i + 1;
            let r = l + 1;
            var m = i;
            if l < n && lt(xs[l], xs[m]) { m = l; }
            if r < n && lt(xs[r], xs[m]) { m = r; }
            if m == i { break; }
            let t = xs[i];
            xs[i] = xs[m];
            xs[m] = t;
            i = m;
        }
    }
    top
}
@module shop
use rng;
use pq;

pub enum Event {
    Arrive(Int, Int, Int),
    Order(Int, Str, Int, Int),
    Restock(Int, Int),
    Audit(Int),
}

pub struct Item { name: Str, price: Float, stock: [Int], sold: [Int] }

trait Timed {
    fn at(self) -> Int;
}

impl Timed for Event {
    fn at(self) -> Int {
        match self {
            Arrive(t, _, _) -> t,
            Order(t, _, _, _) -> t,
            Restock(t, _) -> t,
            Audit(t) -> t,
        }
    }
}

fn itemName(i: Int) -> Str {
    let parts = ["bolt", "nut", "gear", "cog", "spring", "valve", "pipe", "wire"];
    parts[i % 8] ++ "-" ++ showIntRadix(i, 16)
}

fn customer(r: rng::Rng) -> Str {
    let first = ["ana", "bo", "cy", "dee", "eli", "fay", "gus", "hal", "ivy", "jo"];
    first[rng::below(r, 10)] ++ showInt(rng::below(r, 400))
}

pub fn simulate(n: Int, seed: Int) {
    let r = rng::new(seed);
    let nitems = 600;
    var items: [Item] = listNew();
    for i in 0 .. nitems {
        push(items, Item.{ name: itemName(i), price: 1.0 + toFloat(rng::below(r, 9000)) / 100.0, stock: [20], sold: [0] });
    }
    var q: pq::Heap<(Int, Int, Event)> = pq::new(|a: (Int, Int, Event), b: (Int, Int, Event)| {
        let (ta, sa, _) = a;
        let (tb, sb, _) = b;
        ta < tb || (ta == tb && sa < sb)
    });
    var seq = 0;
    for k in 0 .. 64 {
        let e = Order(rng::below(r, 100), customer(r), rng::below(r, nitems), 1 + rng::below(r, 5));
        pq::add(q, (e.at(), seq, e));
        seq = seq + 1;
    }
    pq::add(q, (500, seq, Audit(500)));
    seq = seq + 1;
    var spent: #[Str: Float] = mapNew();
    var backlog: #[Int: Int] = mapNew();
    var processed = 0;
    var revenue = 0.0;
    var missed = 0;
    var audits: [Str] = listNew();
    while processed < n && pq::size(q) > 0 {
        let (now, _, ev) = pq::take(q);
        processed = processed + 1;
        match ev {
            Order(t, who, it, qty) -> {
                let item = items[it];
                if item.stock[0] >= qty {
                    item.stock[0] = item.stock[0] - qty;
                    item.sold[0] = item.sold[0] + qty;
                    let amt = item.price * toFloat(qty);
                    revenue = revenue + amt;
                    spent[who] = mapGetOr(spent, who, 0.0) + amt;
                } else {
                    missed = missed + 1;
                    backlog[it] = mapGetOr(backlog, it, 0) + qty;
                    if item.stock[0] < 5 {
                        let d = Restock(t + 3 + rng::below(r, 20), it);
                        pq::add(q, (d.at(), seq, d));
                        seq = seq + 1;
                    }
                }
                let nx = Order(t + 1 + rng::below(r, 6), customer(r), (it * 7 + rng::below(r, 50)) % nitems, 1 + rng::below(r, 5));
                pq::add(q, (nx.at(), seq, nx));
                seq = seq + 1;
            }
            Restock(t, it) -> {
                let a = Arrive(t + 1 + rng::below(r, 10), it, 10 + rng::below(r, 40) + mapGetOr(backlog, it, 0));
                mapDel(backlog, it);
                pq::add(q, (a.at(), seq, a));
                seq = seq + 1;
            }
            Arrive(_, it, qty) -> {
                let item = items[it];
                item.stock[0] = item.stock[0] + qty;
            }
            Audit(t) -> {
                var low = 0;
                var value = 0.0;
                for item in items {
                    if item.stock[0] < 5 { low = low + 1; }
                    value = value + item.price * toFloat(item.stock[0]);
                }
                push(audits, fmt("t={} low={} stockvalue={}", [showInt(t), showInt(low), showFloatAt(value, 2)]));
                let a = Audit(t + 1500);
                pq::add(q, (a.at(), seq, a));
                seq = seq + 1;
            }
        }
        if processed == n { print("stopped at time " ++ showInt(now)); }
    }
    print(fmt("events={} revenue={} missed={} customers={} queue={}", [showInt(processed), showFloatAt(revenue, 2), showInt(missed), showInt(mapLen(spent)), showInt(pq::size(q))]));
    for a in slice(audits, 0, minI(listLen(audits), 6)) { print(a); }
    print("audits " ++ showInt(listLen(audits)));
    let best = sortBy(pairsOf(spent), |a: (Str, Float), b: (Str, Float)| {
        let c = cmpF(snd(b), snd(a));
        if c != 0 { c } else if fst(a) < fst(b) { -1 } else if fst(a) > fst(b) { 1 } else { 0 }
    });
    for (who, amt) in slice(best, 0, 5) { print(padRight(who, 8, ' ') ++ showFloatAt(amt, 2)); }
    let ranked = sortBy(items, |a: Item, b: Item| cmpI(b.sold[0], a.sold[0]));
    print(strJoin(listMap(slice(ranked, 0, 5), |i: Item| i.name ++ ":" ++ showInt(i.sold[0])), " "));
}
@module text
use rng;

fn makeWord(r: rng::Rng) -> Str {
    let syl = ["ka", "lo", "mi", "ten", "ra", "su", "vel", "or", "en", "di", "qua", "sto"];
    var n = 1 + rng::below(r, 3);
    if rng::below(r, 10) == 0 { n = n + 2; }
    var w = "";
    for i in 0 .. n { w = w ++ syl[minI(rng::below(r, 12), rng::below(r, 12))]; }
    w
}

fn isVowel(c: Char) -> Bool {
    match c { 'a' -> true, 'e' -> true, 'i' -> true, 'o' -> true, 'u' -> true, _ -> false }
}

pub fn run(nwords: Int, seed: Int) {
    let r = rng::new(seed);
    var parts: [Str] = listNew();
    for i in 0 .. nwords {
        var w = makeWord(r);
        if rng::below(r, 7) == 0 { w = strCat(showChar(toUpperC(charAt(w, 0))), substr(w, 1, strLen(w))); }
        push(parts, w);
        let p = rng::below(r, 20);
        if p == 0 { push(parts, ". "); } else if p == 1 { push(parts, ", "); } else { push(parts, " "); }
    }
    let doc = strJoin(parts, "");
    let n = strLen(doc);
    var freq: #[Str: Int] = mapNew();
    var start = -1;
    var sentences = 0;
    var vowels = 0;
    var hash = 0;
    for i in 0 .. n + 1 {
        let c = if i < n { charAt(doc, i) } else { ' ' };
        if isAlpha(c) {
            if start < 0 { start = i; }
            if isVowel(toLowerC(c)) { vowels = vowels + 1; }
        } else {
            if start >= 0 {
                let w = lower(substr(doc, start, i));
                freq[w] = mapGetOr(freq, w, 0) + 1;
                start = -1;
            }
            if c == '.' { sentences = sentences + 1; }
        }
        hash = (hash * 31 + ord(c)) & 0xffff_ffff;
    }
    print(fmt("chars={} words={} distinct={} sentences={} vowels={} hash={}", [showInt(n), showInt(nwords), showInt(mapLen(freq)), showInt(sentences), showInt(vowels), showInt(hash)]));
    let top = sortBy(pairsOf(freq), |a: (Str, Int), b: (Str, Int)| {
        if snd(a) != snd(b) { cmpI(snd(b), snd(a)) } else if fst(a) < fst(b) { -1 } else { 1 }
    });
    for (w, c) in slice(top, 0, 12) { print(padLeft(showInt(c), 7, ' ') ++ " " ++ w); }
    var lens: #[Int: Int] = mapNew();
    for (w, c) in pairsOf(freq) { lens[strLen(w)] = mapGetOr(lens, strLen(w), 0) + c; }
    let ks = sortBy(keysOf(lens), |a: Int, b: Int| cmpI(a, b));
    print(strJoin(listMap(ks, |k: Int| showInt(k) ++ "=" ++ showInt(lens[k])), " "));
    let sentenceList = strSplit(doc, ". ");
    let longest = listFold(sentenceList, 0, |a: Int, s: Str| maxI(a, listLen(strSplit(s, " "))));
    print("longest sentence words " ++ showInt(longest));
    print("replaced " ++ showInt(strLen(strReplace(substr(doc, 0, 200000), "ka", "KAA"))));
}
@module tree
use rng;

enum Tree { Leaf, Node(Tree, Int, Int, Tree) }

fn insert(t: Tree, k: Int) -> Tree {
    match t {
        Leaf -> Node(Leaf, k, 1, Leaf),
        Node(l, x, c, r) when k < x -> Node(insert(l, k), x, c, r),
        Node(l, x, c, r) when k > x -> Node(l, x, c, insert(r, k)),
        Node(l, x, c, r) -> Node(l, x, c + 1, r),
    }
}

fn depth(t: Tree) -> Int {
    match t { Leaf -> 0, Node(l, _, _, r) -> 1 + maxI(depth(l), depth(r)) }
}

fn sumTree(t: Tree, acc: Int) -> Int {
    match t { Leaf -> acc, Node(l, x, c, r) -> sumTree(r, sumTree(l, acc) * 3 + x * c) & 0xffff_ffff_ffff }
}

fn count(t: Tree) -> Int {
    match t { Leaf -> 0, Node(l, _, c, r) -> count(l) + c + count(r) }
}

fn member(t: Tree, k: Int) -> Bool {
    var cur = t;
    while true {
        match cur {
            Leaf -> { return false; }
            Node(l, x, _, r) -> {
                if k == x { return true; }
                cur = if k < x { l } else { r };
            }
        }
    }
    false
}

fn rangeCount(t: Tree, lo: Int, hi: Int) -> Int {
    match t {
        Leaf -> 0,
        Node(l, x, c, r) -> {
            var s = 0;
            if lo < x { s = s + rangeCount(l, lo, hi); }
            if lo <= x && x < hi { s = s + c; }
            if x < hi { s = s + rangeCount(r, lo, hi); }
            s
        }
    }
}

pub fn run(n: Int, seed: Int) {
    let r = rng::new(seed);
    var t = Leaf;
    for i in 0 .. n { t = insert(t, rng::below(r, n * 4)); }
    print(fmt("count={} depth={} sum={}", [showInt(count(t)), showInt(depth(t)), showInt(sumTree(t, 0))]));
    var hits = 0;
    for i in 0 .. n { if member(t, rng::below(r, n * 4)) { hits = hits + 1; } }
    print("hits " ++ showInt(hits));
    var rc: [Int] = listNew();
    for i in 0 .. 2000 {
        let lo = rng::below(r, n * 4);
        push(rc, rangeCount(t, lo, lo + 200));
    }
    print("ranges " ++ showInt(listFold(rc, 0, |a: Int, b: Int| a + b)) ++ " max " ++ showInt(listFold(rc, 0, |a: Int, b: Int| maxI(a, b))));
}
@module mat
use rng;

fn mul(a: [[Float]], b: [[Float]], n: Int) -> [[Float]] {
    var c: [[Float]] = listNew();
    for i in 0 .. n {
        let row = listRepeat(0.0, n);
        let ai = a[i];
        for k in 0 .. n {
            let aik = ai[k];
            let bk = b[k];
            for j in 0 .. n { row[j] = row[j] + aik * bk[j]; }
        }
        push(c, row);
    }
    c
}

fn normalise(a: [[Float]], n: Int) -> Float {
    var mx = 0.0;
    for row in a { for v in row { mx = maxF(mx, absF(v)); } }
    for row in a { for j in 0 .. n { row[j] = row[j] / mx; } }
    mx
}

pub fn run(n: Int, reps: Int) {
    let r = rng::new(5);
    var a: [[Float]] = listNew();
    for i in 0 .. n {
        var row: [Float] = listNew();
        for j in 0 .. n { push(row, rng::unit(r) - 0.5); }
        push(a, row);
    }
    var m = a;
    for k in 0 .. reps {
        m = mul(m, a, n);
        print("scale " ++ showFloatAt(normalise(m, n), 9));
    }
    var tr = 0.0;
    for i in 0 .. n { tr = tr + m[i][i]; }
    print("trace " ++ showFloatAt(tr, 12));
    print("corner " ++ showFloat(m[0][0]) ++ " " ++ showFloat(m[n - 1][n - 1]));
}
'''

# Weights for gen_tests.MINI_TEMPLATES: mostly loop-bearing programs, a
# minority of programs that end in an interpreter error, and few that run into
# the step guard.
INTERP_WEIGHTS = [3, 2, 2, 3, 2, 3, 1, 1, 1, 1, 2, 0.5]


def interp_source(count=300):
    r = random.Random(5151)
    progs = []
    for _ in range(count):
        t = r.choices(g.MINI_TEMPLATES, weights=INTERP_WEIGHTS)[0]
        progs.append(t.format(n=r.randint(2, 400), a=r.randint(1, 12000), b=r.randint(1, 50)))
    return g.interp_program(progs, guard=50000, width=70)


def compile_source(nfuncs=2750):
    return g.IntProgGen(7373, nfuncs, 64, budget=6000).build()


CASES = [
    ('001_mixed_application', lambda: MIXED),
    ('002_interpreter_in_vellum', interp_source),
    ('003_large_program_compile', compile_source),
]

# Long tier (--long, written to ../bench-long). 001 runs the same application
# with every phase scaled up; 002 interprets ten times as many mini-programs;
# 003 compiles a larger generated program under the raised stdin limit in
# SPEC.md.
LONG_STDIN_LIMIT = 8000000
MIXED_LONG = (MIXED
              .replace('shop::simulate(100000, 41);', 'shop::simulate(700000, 41);')
              .replace('text::run(100000, 7);', 'text::run(600000, 7);')
              .replace('tree::run(50000, 99);', 'tree::run(350000, 99);')
              .replace('mat::run(80, 3);', 'mat::run(80, 21);'))
LONG_CASES = [
    ('001_mixed_application', lambda: MIXED_LONG),
    ('002_interpreter_in_vellum', lambda: interp_source(3500)),
    ('003_large_program_compile', lambda: compile_source(10800)),
]


def reference(src):
    proc = subprocess.run([sys.executable, 'main.py'], input=src.encode('utf-8'),
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          cwd=os.path.join(PROBLEM, 'reference'), timeout=3600)
    if proc.returncode != 0:
        raise RuntimeError(proc.stderr.decode('utf-8', 'replace')[-2000:])
    return proc.stdout.decode('utf-8')


def main():
    expected = '--no-expected' not in sys.argv[1:]
    out_dir, cases, limit = HERE, CASES, STDIN_LIMIT
    if '--long' in sys.argv[1:]:
        out_dir, cases, limit = os.path.join(PROBLEM, 'bench-long'), LONG_CASES, LONG_STDIN_LIMIT
        os.makedirs(out_dir, exist_ok=True)
    for name, make in cases:
        src = make()
        assert len(src.encode('utf-8')) <= limit, name
        with open(os.path.join(out_dir, name + '.in'), 'w', encoding='utf-8', newline='\n') as f:
            f.write(src)
        if expected:
            out = reference(src)
            with open(os.path.join(out_dir, name + '.out'), 'w', encoding='utf-8', newline='\n') as f:
                f.write(out)
        print(name, len(src), 'bytes')


if __name__ == '__main__':
    main()
