#!/usr/bin/env python3
"""Build the whole langvm test suite: hand-written cases plus generated ones.

Every expected output comes from running the reference implementation in a
subprocess, exactly as the harness runs an implementation.  All randomness is
seeded with fixed constants, so re-running this script reproduces the suite
byte for byte.

Layout (section "Held-out tests" of problems/README.md): one shared number sequence
across both directories, about a quarter of each feature area public in
problems/langvm/tests/ and the rest held out in
problems/langvm/heldout/.

Usage:
    python3 gen_tests.py            write both test directories
    python3 gen_tests.py --list     print the case table without running
"""

import os
import random
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REF = os.path.join(HERE, 'reference')
SPEC = os.path.join(HERE, 'SPEC.md')
PUBLIC_DIR = os.path.join(HERE, 'tests')
HIDDEN_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "heldout")

# Areas in suite order: roughly the order of the compiler pipeline, then whole
# programs, then the heavy workloads.  Every area must end up with cases in
# both the public and the hidden directory.
AREA_ORDER = [
    'spec',      # the worked examples of SPEC.md section 17
    'lex',       # tokens, literals, escapes, comments
    'parse',     # grammar, precedence, trailing commas
    'module',    # the module stream, use, visibility, qualified paths
    'item',      # declarations, duplicate names, signatures
    'type',      # type resolution, map keys, Self, arities
    'trait',     # traits, impls, defaults, coherence, dispatch
    'generic',   # inference, generic calls, bounds
    'check',     # type errors, assignment, divergence, missing-return
    'pattern',   # pattern forms, typing, irrefutability
    'exhaust',   # exhaustiveness and reachability
    'control',   # if, while, for, break, return
    'closure',   # lambdas and captures
    'value',     # equality, identity, lists, maps, tuples
    'intlib',
    'floatlib',
    'strlib',
    'listlib',
    'maplib',
    'optlib',    # Option, Result, tuples, fmt
    'runtime',   # panics, evaluation order, call depth
    'diag',      # pass order: which error is reported
    'program',   # whole programs
    'gen',       # generated programs
    'heavy',     # the performance ceiling
]

CASES = []
_SEEN = set()


def add(area, name, src, pub=None, expect=None):
    """Record one case.  `pub` hints public (True), forces hidden (False)
    or forces public ('always');
    `expect`, when given, is a prefix the case's outcome must have ('ok',
    'panic' or 'error <kind>'), so a generator mistake cannot slip through."""
    assert area in AREA_ORDER, area
    assert re.fullmatch(r'[a-z0-9_]+', name), name
    key = (area, name)
    assert key not in _SEEN, 'duplicate case %s' % (key,)
    _SEEN.add(key)
    CASES.append({'area': area, 'name': name, 'src': src,
                  'pub': True if pub == 'always' else pub,
                  'always': pub == 'always', 'expect': expect})


PANIC_MESSAGES = {
    'divide by zero', 'modulo by zero', 'shift amount out of range',
    'index out of bounds', 'missing key', 'no match', 'unwrap of None',
    'unwrap of Err', 'unwrap of Ok', 'empty list', 'invalid char code',
    'float out of integer range', 'negative count', 'negative exponent',
    'empty separator', 'bad format', 'radix out of range',
    'digits out of range', 'call stack overflow',
}


def outcome_key(out):
    """The error kind or panic message an output ends with, else None."""
    lines = out.rstrip('\n').split('\n')
    if len(lines) == 1 and re.fullmatch(r'error: [a-z-]+ at \d+:\d+', lines[0]):
        return lines[0].split(' at ')[0]
    m = re.search(r'panic: (.*)$', out.rstrip('\n'))
    if m and 'panic: ' in lines[-1]:
        return 'panic: ' + (m.group(1) if m.group(1) in PANIC_MESSAGES else '<custom>')
    return None


def assign_visibility(outs):
    """Choose the public cases: about a quarter of each area, spread over it.

    First, for every error kind and panic message that occurs, the shortest
    case producing it is made public, so an implementer can debug every
    diagnostic from the public tests.  Then each area is topped up to a
    quarter (at least one public and one hidden case per area): cases added
    with pub=True are preferred, pub=False keeps a case hidden, and the rest of
    the share is spread evenly over the area so it spans the difficulty range.
    Finally, a kind or message whose cases all ended up public gets one of
    them moved back to hidden, so both sets cover it.
    """
    best = {}
    for i, case in enumerate(CASES):
        key = outcome_key(outs[i])
        if key is None or case['pub'] is False:
            continue
        if key not in best or len(case['src']) < len(CASES[best[key]]['src']):
            best[key] = i
    forced = set(best.values())
    forced |= {i for i, case in enumerate(CASES) if case['always']}
    per_area = {}
    for i, case in enumerate(CASES):
        per_area.setdefault(case['area'], []).append(i)
    for area, idxs in per_area.items():
        n = len(idxs)
        want = max(1, min(n - 1, round(n * 0.25)))
        chosen = [i for i in idxs if i in forced]
        hinted = [i for i in idxs if CASES[i]['pub'] is True and i not in forced]
        free = [i for i in idxs if CASES[i]['pub'] is None and i not in forced]
        k = want - len(chosen)
        if k > 0 and hinted:
            take = min(k, len(hinted))
            step = len(hinted) / take
            chosen += [hinted[int(j * step)] for j in range(take)]
            k -= take
        if k > 0 and free:
            take = min(k, len(free))
            step = len(free) / take
            chosen += [free[int(j * step)] for j in range(take)]
        if len(chosen) >= n:
            chosen = chosen[:n - 1]
        chosen = set(chosen)
        for i in idxs:
            CASES[i]['pub'] = i in chosen
    # Keep every error kind and panic message in the hidden set as well,
    # whenever it has a second case.
    by_key = {}
    for i, case in enumerate(CASES):
        key = outcome_key(outs[i])
        if key is not None:
            by_key.setdefault(key, []).append(i)
    for key, idxs in by_key.items():
        movable = [i for i in idxs if i not in forced]
        if len(idxs) > 1 and movable and all(CASES[i]['pub'] for i in idxs):
            CASES[movable[-1]]['pub'] = False


def ordered_cases():
    rank = {a: i for i, a in enumerate(AREA_ORDER)}
    return sorted(range(len(CASES)),
                  key=lambda i: (rank[CASES[i]['area']], i))


def run_reference(src):
    """Return the reference implementation's stdout for one input."""
    proc = subprocess.run([sys.executable, 'main.py'],
                          input=src.encode('utf-8'),
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          cwd=REF, timeout=300)
    if proc.returncode != 0:
        raise RuntimeError('reference failed (%d): %s'
                           % (proc.returncode,
                              proc.stderr.decode('utf-8', 'replace')[-2000:]))
    return proc.stdout.decode('utf-8')


def clean_dir(path):
    os.makedirs(path, exist_ok=True)
    for name in os.listdir(path):
        if name.endswith('.in') or name.endswith('.out'):
            os.unlink(os.path.join(path, name))

def hand_1():
    """Hand-written: exhaustiveness cases of section 12.5, plus assorted semantics."""
    add('exhaust', 'tri_ok', '''@module main
enum Tri { A, B, C(Int) }
fn f(t: Tri) -> Int {
    match t { A -> 1, B -> 2, C(n) -> n }
}
fn main() { print(showInt(f(A))); }
''', True)
    add('exhaust', 'tri_missing_b', '''@module main
enum Tri { A, B, C(Int) }
fn f(t: Tri) -> Int {
    match t { A -> 1, C(_) -> 2 }
}
fn main() { print(showInt(f(A))); }
''', True)
    add('exhaust', 'tri_lit', '''@module main
enum Tri { A, B, C(Int) }
fn f(t: Tri) -> Int {
    match t { A -> 1, B -> 2, C(0) -> 3, C(_) -> 4 }
}
fn main() { print(showInt(f(A))); }
''')
    add('exhaust', 'tri_unreach', '''@module main
enum Tri { A, B, C(Int) }
fn f(t: Tri) -> Int {
    match t { _ -> 0, A -> 1 }
}
fn main() { print(showInt(f(A))); }
''')
    add('exhaust', 'tri_guard', '''@module main
enum Tri { A, B, C(Int) }
fn f(t: Tri) -> Int {
    match t { A when f(B) == 2 -> 1, A -> 2, B -> 3, C(_) -> 4 }
}
fn main() { print(showInt(f(A))); }
''')
    add('exhaust', 'list_exh', '''@module main
fn f(xs: [Int]) -> Int {
    match xs { [] -> 0, [a] -> a, [a, b, ..] -> a + b }
}
fn main() { print(showInt(f([1, 2, 3]))); }
''', True)
    add('exhaust', 'list_unreach', '''@module main
fn f(xs: [Int]) -> Int {
    match xs { [] -> 0, [_, ..] -> 1, [..] -> 2 }
}
fn main() { print(showInt(f([1]))); }
''')
    add('exhaust', 'int_nonexh', '''@module main
fn f(n: Int) -> Str {
    match n { 0 -> "z", 1 -> "o" }
}
fn main() { print(f(0)); }
''')
    add('exhaust', 'bool_exh', '''@module main
fn f(b: Bool) -> Int { match b { true -> 1, false -> 0 } }
fn main() { print(showInt(f(true))); }
''', True)
    add('exhaust', 'struct_nonexh', '''@module main
struct Pair { a: Int, b: Int }
fn f(p: Pair) -> Int { match p { Pair.{ a: 1, b: _ } -> 1 } }
fn main() { print(showInt(f(Pair.{ a: 1, b: 2 }))); }
''')
    add('exhaust', 'unit_wild', '''@module main
fn g() {}
fn main() { let u = g(); match u { _ -> print("u") } }
''')
    add('exhaust', 'nested_tuple_exh', '''@module main
fn f(p: (Bool, Bool)) -> Int {
    match p {
        (true, true) -> 3,
        (true, false) -> 2,
        (false, b) -> if b { 1 } else { 0 },
    }
}
fn main() { print(showInt(f((false, true)))); }
''')
    add('exhaust', 'option_exh', '''@module main
fn f(o: Option<Int>) -> Int { match o { Some(n) -> n, None -> -1 } }
fn main() { print(showInt(f(None))); print(showInt(f(Some(5)))); }
''', True)
    add('exhaust', 'no_match_panic', '''@module main
fn f(n: Int) -> Int { match n { x when x > 0 -> 1, x when x < 0 -> -1, _ when false -> 0 } }
fn main() { print(showInt(f(1))); print(showInt(f(0))); }
''')
    add('intlib', 'wrap_mul', '''@module main
fn main() {
    print(showInt(intMax() * 2));
    print(showInt(intMin() * -1));
    print(showInt(absI(intMin())));
    print(showInt(-intMin()));
}
''')
    add('runtime', 'shift_panic', '''@module main
fn main() { print(showInt(1 << 63)); print(showInt(1 << 64)); }
''')
    add('maplib', 'map_order', '''@module main
fn main() {
    var m: #[Str: Int] = mapNew();
    m["a"] = 1; m["b"] = 2; m["a"] = 3;
    print(strJoin(keysOf(m), ","));
    mapDel(m, "a"); m["a"] = 9;
    print(strJoin(keysOf(m), ","));
    print(showInt(mapLen(m)));
}
''', True)
    add('closure', 'closure_capture', '''@module main
fn main() {
    var xs: [fn() -> Int] = listNew();
    var i = 0;
    while i < 3 {
        let j = i;
        push(xs, || j);
        i = i + 1;
    }
    for f in xs { emit(showInt(f())); }
    print("");
}
''', True)
    add('runtime', 'deep_recursion', '''@module main
fn down(n: Int) -> Int { if n == 0 { return 0; } down(n - 1) + 1 }
fn main() { print(showInt(down(15000))); }
''', True)
    add('runtime', 'stack_overflow', '''@module main
fn down(n: Int) -> Int { if n == 0 { return 0; } down(n - 1) + 1 }
fn main() { print(showInt(down(30000))); }
''', True)
    add('listlib', 'sort_by_stable', '''@module main
fn main() {
    let xs = [3, 1, 2, 1];
    let ys = sortBy(xs, |a, b| cmpI(a, b));
    print(strJoin(listMap(ys, |v| showInt(v)), " "));
    let zs = sortBy(xs, |a, b| 0);
    print(strJoin(listMap(zs, |v| showInt(v)), " "));
}
''', True)
    add('optlib', 'fmt_errors', '''@module main
fn main() {
    print(fmt("{{}}", []));
    print(fmt("a{}b", ["x"]));
    print(fmt("{} {}", ["x"]));
}
''', True)
    add('strlib', 'str_index', '''@module main
fn main() {
    let s = "abc";
    print(showChar(s[1]));
    print(showInt(strLen(s)));
    print(showChar(s[3]));
}
''', True)
    add('floatlib', 'float_ops', '''@module main
fn main() {
    print(showFloat(1.0 / 0.0));
    print(showFloat(-1.0 / 0.0));
    print(showFloat(0.0 / 0.0));
    print(showFloat(floorF(-0.0)));
    print(showFloat(ceilF(-0.5)));
    print(showFloat(fmodF(5.5, 2.0)));
    print(showFloat(fmodF(1.0, 0.0)));
    print(showFloat(minF(nanF(), 1.0)));
    print(showFloat(maxF(nanF(), 1.0)));
    print(showFloat(minF(-0.0, 0.0)));
    print(showInt(floatBits(floatFromBits(-1))));
}
''', True)

def hand_2():
    """Hand-written: one program per error kind: all 51 kinds of section 13.4."""
    add('module', 'bad_module', '''fn main() {}
''', True)
    add('module', 'bad_module2', '''@module main
@module  x
''')
    add('module', 'bad_module3', '''''')
    add('module', 'dup_module', '''@module main
fn main() {}
@module a
@module a
''')
    add('lex', 'bad_token', '''@module main
fn main() { let x = $1; }
''', True)
    add('lex', 'bad_token_hex', '''@module main
fn main() { let x = 0x_1; }
''')
    add('lex', 'int_range', '''@module main
fn main() { let x = 9223372036854775808; }
''', True)
    add('lex', 'bad_escape', '@module main\nfn main() { let x = "a\\q"; }\n')
    add('lex', 'bad_escape_u', "@module main\nfn main() { let c = '\\u{d800}'; }\n")
    add('lex', 'unterminated_str', '''@module main
fn main() { let x = "ab; }
''', True)
    add('lex', 'unterminated_char', '''@module main
fn main() { let c = 'ab'; }
''')
    add('lex', 'unterminated_comment', '''@module main
fn main() {}
/* a /* b */
''')
    add('parse', 'parse', '''@module main
fn main( {}
''', True)
    add('parse', 'parse_chain', '''@module main
fn main() { let b = 1 < 2 < 3; }
''')
    add('item', 'reserved_name', '''@module main
struct Int { x: Int }
fn main() {}
''', True)
    add('item', 'dup_name_item', '''@module main
fn f() {}
fn f() {}
fn main() {}
''', True)
    add('item', 'dup_name_variant', '''@module main
enum A { X }
enum B { X }
fn main() {}
''')
    add('item', 'dup_name_field', '''@module main
struct S { a: Int, a: Int }
fn main() {}
''')
    add('item', 'dup_name_param', '''@module main
fn f(a: Int, a: Int) {}
fn main() {}
''')
    add('item', 'dup_name_generic', '''@module main
fn f<T, T>(a: T) {}
fn main() {}
''')
    add('module', 'dup_name_import', '''@module main
use other;
use other as other;
fn main() {}
@module other
''')
    add('pattern', 'dup_name_pattern', '''@module main
fn main() { let (a, a) = (1, 2); }
''', True)
    add('module', 'unknown_module_use', '''@module main
use nope;
fn main() {}
''')
    add('module', 'unknown_module_path', '''@module main
fn main() { print(no::x()); }
''')
    add('type', 'unknown_type', '''@module main
fn f(x: Nope) {}
fn main() {}
''', True)
    add('type', 'unknown_trait', '''@module main
fn f<T: Nope>(x: T) {}
fn main() {}
''')
    add('module', 'not_public', '''@module main
use o;
fn f(x: o::S) {}
fn main() {}
@module o
struct S { a: Int }
''', True)
    add('type', 'arity_type', '''@module main
fn f(x: Option) {}
fn main() {}
''', True)
    add('type', 'bad_arity_type', '''@module main
fn f(x: (Int, Int, Int, Int, Int, Int, Int, Int, Int)) {}
fn main() {}
''')
    add('type', 'bad_key_type_sig', '''@module main
fn f(m: #[Float: Int]) {}
fn main() {}
''')
    add('type', 'self_outside_type', '''@module main
fn f(x: Self) {}
fn main() {}
''', True)
    add('type', 'self_outside_expr', '''@module main
fn main() { print(showInt(self)); }
''')
    add('trait', 'builtin_trait_impl', '''@module main
impl Eq for Int {}
fn main() {}
''', True)
    add('trait', 'bad_impl_head', '''@module main
trait T { fn m(self); }
impl T for [Int] { fn m(self) {} }
fn main() {}
''')
    add('trait', 'unused_param', '''@module main
trait T { fn m(self); }
impl<A> T for Int { fn m(self) {} }
fn main() {}
''')
    add('trait', 'dup_impl', '''@module main
trait T { fn m(self); }
impl T for Int { fn m(self) {} }
impl T for Int { fn m(self) {} }
fn main() {}
''', True)
    add('trait', 'missing_method', '''@module main
trait T { fn m(self); fn n(self); }
impl T for Int { fn m(self) {} }
fn main() {}
''', True)
    add('trait', 'extra_method', '''@module main
trait T { fn m(self); }
impl T for Int { fn m(self) {} fn q(self) {} }
fn main() {}
''')
    add('trait', 'sig_mismatch', '''@module main
trait T { fn m(self) -> Int; }
impl T for Int { fn m(self) -> Str { "x" } }
fn main() {}
''', True)
    add('module', 'no_main', '''@module other
fn f() {}
''', True)
    add('module', 'no_main_args', '''@module main
fn main(x: Int) {}
''')
    add('module', 'no_main_ret', '''@module main
fn main() -> Int { 1 }
''')
    add('check', 'unknown_name', '''@module main
fn main() { print(nope); }
''', True)
    add('check', 'type_mismatch', '''@module main
fn main() { let x: Int = "s"; }
''', True)
    add('check', 'arity', '''@module main
fn f(a: Int) {}
fn main() { f(1, 2); }
''', True)
    add('check', 'not_callable', '''@module main
fn main() { let x = 1; print(showInt(x(2))); }
''')
    add('check', 'not_struct', '''@module main
fn main() { let x = 1; print(showInt(x.f)); }
''', True)
    add('check', 'unknown_field', '''@module main
struct S { a: Int }
fn main() { let s = S.{ a: 1 }; print(showInt(s.b)); }
''', True)
    add('check', 'missing_field', '''@module main
struct S { a: Int, b: Int }
fn main() { let s = S.{ a: 1 }; }
''')
    add('check', 'dup_field', '''@module main
struct S { a: Int }
fn main() { let s = S.{ a: 1, a: 2 }; }
''')
    add('check', 'not_indexable', '''@module main
fn main() { let x = 1; print(showInt(x[0])); }
''', True)
    add('check', 'not_iterable', '''@module main
fn main() { for x in 1 { print("x"); } }
''', True)
    add('trait', 'no_method', '''@module main
fn main() { print(showInt(3.go())); }
''', True)
    add('trait', 'ambig_method', '''@module main
trait A { fn go(self) -> Int; }
trait B { fn go(self) -> Int; }
impl A for Int { fn go(self) -> Int { 1 } }
impl B for Int { fn go(self) -> Int { 2 } }
fn main() { print(showInt(3.go())); }
''', True)
    add('trait', 'unsatisfied_bound', '''@module main
trait T { fn m(self) -> Int; }
fn f<X: T>(x: X) -> Int { x.m() }
fn main() { print(showInt(f(1))); }
''', True)
    add('trait', 'unsatisfied_bound_method', '''@module main
trait T { fn m(self) -> Int; }
fn main() { print(showInt(3.m())); }
''')
    add('value', 'not_eq', '''@module main
fn main() { let f = |x: Int| x; print(showBool(f == f)); }
''', True)
    add('value', 'not_ord', '''@module main
fn main() { print(showBool((1, 2) < (3, 4))); }
''', True)
    add('generic', 'cannot_infer', '''@module main
fn main() { let x = None; }
''', True)
    add('generic', 'cannot_infer_lambda', '''@module main
fn main() { let f = |x| x; }
''')
    add('exhaust', 'non_exhaustive', '''@module main
fn main() { match 1 { 0 -> print("z") } }
''', True)
    add('exhaust', 'unreachable', '''@module main
fn main() { match 1 { _ -> print("a"), 1 -> print("b") } }
''', True)
    add('check', 'missing_return', '''@module main
fn f() -> Int { let x = 1; }
fn main() { print(showInt(f())); }
''', True)
    add('check', 'missing_return_lambda', '''@module main
fn main() { let f = |x: Int| -> Int { let y = x; }; print(showInt(f(1))); }
''')
    add('check', 'bad_value_ref', '''@module main
fn g() {}
fn main() { let x = g; }
''', True)
    add('check', 'bad_value_ref_type', '''@module main
struct S { a: Int }
fn main() { let x = S; }
''')
    add('pattern', 'bad_pattern', '''@module main
fn main() { match 1.5 { 1.5 -> print("a"), _ -> print("b") } }
''', True)
    add('pattern', 'refutable_pattern', '''@module main
fn main() { let Some(x) = Some(1); }
''', True)
    add('pattern', 'refutable_for', '''@module main
fn main() { for Some(x) in [Some(1)] { print("a"); } }
''')
    add('control', 'break_outside', '''@module main
fn main() { break; }
''', True)
    add('control', 'break_in_lambda', '''@module main
fn main() { for i in 0 .. 2 { let f = || { break; }; } }
''')
    add('check', 'assign_immutable', '''@module main
fn main() { let x = 1; x = 2; }
''', True)
    add('check', 'assign_captured', '''@module main
fn main() { var x = 1; let f = || { x = 2; }; }
''')
    add('check', 'bad_target', '''@module main
struct S { a: Int }
fn main() { let s = S.{ a: 1 }; s.a = 2; }
''', True)
    add('check', 'bad_target_str', '''@module main
fn main() { var s = "ab"; s[0] = 'c'; }
''')

def hand_3():
    """Hand-written: traits, generics, modules, closures and library edge cases."""
    add('trait', 'trait_default_self', '''@module main
trait Greet {
    fn name(self) -> Str;
    fn hello(self) -> Str { "hi " ++ self.name() }
}
impl Greet for Int { fn name(self) -> Str { showInt(self) } }
impl Greet for Str { fn name(self) -> Str { self } }
impl Greet for Char { fn name(self) -> Str { showChar(self) } }
fn main() {
    print(1.hello());
    print("bob".hello());
    print('c'.hello());
    print(Greet::hello(7));
}
''', True)
    add('trait', 'impl_map_and_list', '''@module main
trait Size { fn size(self) -> Int; }
impl<K: Key, V> Size for #[K: V] { fn size(self) -> Int { mapLen(self) } }
impl<T> Size for [T] { fn size(self) -> Int { listLen(self) } }
impl Size for Unit { fn size(self) -> Int { 0 } }
fn nothing() {}
fn main() {
    print(showInt(#[1: "a", 2: "b"].size()));
    print(showInt([1, 2, 3].size()));
    let u = nothing();
    print(showInt(u.size()));
}
''', True)
    add('generic', 'generic_nested_angle', '''@module main
fn wrap(x: Int) -> Option<Option<Int>> { Some(Some(x)) }
fn main() {
    match wrap(3) {
        Some(Some(n)) -> print(showInt(n)),
        Some(None) -> print("inner none"),
        None -> print("none"),
    }
    let xs: [[Int]] = [[1], [2, 3]];
    print(showInt(listLen(listFlatten(xs))));
}
''')
    add('lex', 'nested_comment', '''@module main
/* a /* b */ still comment */
fn main() { // line
    print("ok"); /* tail */
}
''', True)
    add('closure', 'struct_closure_field', '''@module main
struct Box { f: fn(Int) -> Int, n: Int }
fn apply(b: Box) -> Int { (b.f)(b.n) }
fn main() {
    let b = Box.{ f: |x: Int| x * 2, n: 21 };
    print(showInt(apply(b)));
}
''')
    add('control', 'mutate_while_iterating', '''@module main
fn main() {
    var xs = [1, 2, 3];
    var count = 0;
    for x in xs {
        count = count + 1;
        if count == 2 { push(xs, 99); }
        if count > 10 { break; }
    }
    print(showInt(count));
    print(showInt(listLen(xs)));
}
''')
    add('module', 'self_import', '''@module main
use main as me;
fn helper() -> Int { 5 }
fn main() { print(showInt(me::helper())); }
''')
    add('value', 'eq_recursive', '''@module main
struct Node { v: Int, next: Option<Node> }
fn main() {
    let a = Node.{ v: 1, next: None };
    let b = Node.{ v: 1, next: None };
    print(showBool(a == b));
    let c = Node.{ v: 1, next: Some(a) };
    print(showBool(a == c));
}
''', True)
    add('value', 'eq_fn_field', '''@module main
struct Bad { f: fn(Int) -> Int }
fn main() {
    let a = Bad.{ f: |x: Int| x };
    print(showBool(a == a));
}
''')
    add('value', 'map_eq_order', '''@module main
fn main() {
    print(showBool(#[1: "a", 2: "b"] == #[2: "b", 1: "a"]));
    print(showBool(#[1: "a"] == #[1: "b"]));
}
''')
    add('value', 'tuple_eq', '''@module main
fn main() {
    print(showBool((1, "a", 'c') == (1, "a", 'c')));
    print(showBool([1, 2] == [1, 2]));
    print(showBool(Some([1]) == Some([1])));
}
''')
    add('generic', 'let_option_annot', '''@module main
fn main() {
    let x: Option<Int> = None;
    print(showBool(isNone(x)));
    let ys: [Int] = [];
    print(showInt(listLen(ys)));
    let m: #[Str: Int] = #[];
    print(showInt(mapLen(m)));
}
''', True)
    add('intlib', 'int_edge', '''@module main
fn main() {
    print(showInt(divFloor(7, -2)) ++ " " ++ showInt(modFloor(7, -2)));
    print(showInt(divFloor(intMin(), -1)));
    print(showInt(powI(2, 63)));
    print(showInt(gcdI(0, 0)) ++ " " ++ showInt(gcdI(intMin(), 0)));
    print(showIntRadix(intMin(), 36));
    print(showInt(clz(0)) ++ " " ++ showInt(ctz(0)) ++ " " ++ showInt(popCount(-1)));
    print(showBool(parseInt("9223372036854775808") == None));
    print(showInt(unwrapOr(parseInt("+7"), 0)));
    print(showBool(parseInt(" 7") == None) ++ " " ++ showBool(parseInt("") == None));
    print(showInt(unwrapOr(parseIntRadix("zz", 36), 0)));
}
''', True)
    add('floatlib', 'float_show', '''@module main
fn main() {
    print(showFloatAt(1.0 / 3.0, 0));
    print(showFloatAt(2.675, 2));
    print(showFloat(powF(1.0000001, 100)));
    print(showFloat(powF(2.0, 0)));
    print(showInt(truncToInt(2.9)) ++ " " ++ showInt(truncToInt(-2.9)));
    print(showFloat(toFloat(intMin())));
    print(showBool(isNanF(sqrtF(-1.0))) ++ " " ++ showFloat(sqrtF(-0.0)));
    print(showFloat(roundF(0.5)) ++ " " ++ showFloat(roundF(-0.5)));
    print(showInt(cmpF(nanF(), nanF())) ++ showInt(cmpF(1.0, nanF())) ++ showInt(cmpF(-0.0, 0.0)));
    print(showBool(unwrapOr(parseFloat("1e400"), 0.0) == infF()));
    print(showBool(isNone(parseFloat("inf"))) ++ " " ++ showFloat(unwrapOr(parseFloat(".5"), 0.0)));
    print(showFloat(unwrapOr(parseFloat("12."), 0.0)));
}
''', True)
    add('strlib', 'string_lib', '@module main\nfn main() {\n    print(strJoin(strSplit("aaa", "aa"), "|"));\n    print(strJoin(strSplit("", ","), "|"));\n    print(showInt(strIndexOf("abc", "")) ++ " " ++ showInt(strLastIndexOf("abc", "")));\n    print(quoteStr("a\\\\b\\"c\\u{1}"));\n    print(quoteChar(\'\\n\') ++ quoteChar(\'\\\\\') ++ quoteChar(\'"\'));\n    print(padLeft("abc", 2, \'0\') ++ "|" ++ padRight("", 3, \'x\'));\n    print(upper("aZ9é") ++ lower("AZ9É"));\n    print(showInt(strCmp("", "a")) ++ showInt(strCmp("a", "")));\n    print(strOfChars(chars("héllo")));\n    print(trim("\\t x \\n") ++ "|" ++ trimLeft(" x ") ++ "|" ++ trimRight(" x "));\n    print(strReplace("hello", "l", "L"));\n    print(showBool(strContains("abc", "bc")) ++ showBool(startsWith("abc", "ab")) ++ showBool(endsWith("abc", "bc")));\n}\n', True)
    add('listlib', 'list_lib', '''@module main
fn main() {
    var xs = [1, 2, 3];
    insert(xs, 0, 0);
    print(strJoin(listMap(xs, |v| showInt(v)), ","));
    print(showInt(removeAt(xs, 1)));
    print(showInt(pop(xs)));
    print(showBool(listContains(xs, 2)) ++ showInt(listIndexOf(xs, 2)));
    let ys = listRepeat(7, 3);
    print(strJoin(listMap(ys, |v| showInt(v)), ","));
    print(showInt(listLen(slice(ys, 1, 3))));
    print(strJoin(listMap(reverseList([1, 2]), |v| showInt(v)), ","));
    print(showInt(listFindIndex([1, 2, 3], |v| v > 1)));
    print(showBool(isNone(listFind([1], |v| v > 5))));
    print(showInt(listLen(listZip([1, 2], ["a"]))));
    print(showBool(listAll([1, 2], |v| v > 0)) ++ showBool(listAny([1], |v| v > 5)));
    clear(xs);
    print(showInt(listLen(xs)));
    print(showInt(listFirst([9, 8])) ++ showInt(listLast([9, 8])));
}
''', True)
    add('optlib', 'panics', '''@module main
fn main() {
    print(showInt(unwrapOr(mapGet(#[1: 2], 3), -1)));
    print(showInt(unwrap(mapGet(#[1: 2], 3))));
}
''', True)
    add('runtime', 'panic_custom', '''@module main
fn main() { emit("a"); panic("boom"); print("no"); }
''')
    add('optlib', 'result_lib', '''@module main
fn d(a: Int, b: Int) -> Result<Int, Str> {
    if b == 0 { return Err("div0"); }
    Ok(a / b)
}
fn main() {
    print(showBool(isOk(d(4, 2))) ++ showBool(isErr(d(1, 0))));
    print(showInt(unwrapOk(d(4, 2))));
    print(unwrapErr(d(1, 0)));
    print(showInt(unwrapOk(d(1, 0))));
}
''', True)
    add('trait', 'method_on_generic_param', '''@module main
trait Show { fn show(self) -> Str; }
impl Show for Int { fn show(self) -> Str { showInt(self) } }
impl<T: Show> Show for [T] {
    fn show(self) -> Str { "[" ++ strJoin(listMap(self, |x| x.show()), ",") ++ "]" }
}
fn render<T: Show>(x: T) -> Str { x.show() }
fn main() {
    print(render([[1, 2], [3]]));
    print(render(5));
}
''')
    add('module', 'shadow_builtin', '''@module main
fn print(x: Int) -> Int { x }
fn main() { let y = print(3); emit("v"); }
''')
    add('module', 'shadow_option', '''@module main
enum Option { Nothing, Just(Int) }
fn f(o: Option) -> Int { match o { Nothing -> 0, Just(n) -> n } }
fn main() { print(showInt(f(Just(4)))); print(showInt(f(Nothing))); }
''')
    add('runtime', 'order_eval', '''@module main
fn p(s: Str, v: Int) -> Int { emit(s); v }
fn main() {
    let x = p("a", 1) + p("b", 2);
    print("");
    let m = #[p("k", 1): p("v", 2)];
    print("");
    var xs = [1];
    xs[p("i", 0)] = p("e", 9);
    print(showInt(xs[0]));
}
''', True)
    add('runtime', 'struct_eval_order', '''@module main
struct S { a: Int, b: Int }
fn p(s: Str, v: Int) -> Int { emit(s); v }
fn main() {
    let s = S.{ b: p("b", 1), a: p("a", 2) };
    print(showInt(s.a) ++ showInt(s.b));
}
''')
    add('runtime', 'short_circuit', '''@module main
fn t(s: Str) -> Bool { emit(s); true }
fn f(s: Str) -> Bool { emit(s); false }
fn main() {
    print(showBool(f("1") && t("2")));
    print(showBool(t("3") || t("4")));
}
''', True)

def hand_4():
    """Hand-written: inference, captures, arity limits and pass order."""
    add('check', 'bad_arity_call', '''@module main
fn f(a: Int) {}
fn main() { f(1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1); }
''')
    add('check', 'bad_arity_tuple', '''@module main
fn main() { let t = (1, 1, 1, 1, 1, 1, 1, 1, 1); }
''')
    add('check', 'check_mode_ret_mismatch', '''@module main
fn f() -> Str { "s" }
fn main() { let x: Int = f(); }
''')
    add('generic', 'cannot_infer_nested', '''@module main
fn main() { let xs: [Int] = []; push(xs, listNew()); }
''')
    add('generic', 'cannot_infer_fold', '''@module main
fn main() { print(showInt(listLen(listFold([1], listNew(), |a: [Int], x: Int| a)))); }
''')
    add('trait', 'trait_path_zero_args', '''@module main
trait T { fn m(self) -> Int; }
impl T for Int { fn m(self) -> Int { 1 } }
fn main() { print(showInt(T::m())); }
''')
    add('trait', 'method_no_call', '''@module main
trait T { fn m(self) -> Int; }
impl T for Int { fn m(self) -> Int { 1 } }
fn main() { let x = 1; print(showInt(x.m)); }
''')
    add('closure', 'nested_capture', '''@module main
fn main() {
    let a = 1;
    let f = || {
        let g = || a + 1;
        g()
    };
    print(showInt(f()));
}
''', True)
    add('closure', 'nested_assign_captured', '''@module main
fn main() {
    var a = 1;
    let f = || { let g = || { a = 2; }; g() };
    f();
}
''')
    add('module', 'two_aliases', '''@module main
use o;
use o as p;
fn main() { print(showInt(o::v() + p::v())); }
@module o
pub fn v() -> Int { 3 }
''')
    add('diag', 'pass_order_lex_beats_parse', '''@module main
fn main( {}
@module b
fn f() { let x = $; }
''')
    add('diag', 'pass_order_items_beats_body', '''@module main
fn main() { let x: Int = "s"; }
struct S { a: Nope }
''', True)
    add('diag', 'pass_order_dup_module_beats_lex', '''@module a
@module a
@module main
fn main() { let x = $; }
''')
    add('diag', 'pass_order_reserved_beats_sig', '''@module main
struct Str { a: Nope }
fn main() {}
''')
    add('closure', 'for_range_closure', '''@module main
fn main() {
    var fs: [fn() -> Int] = listNew();
    for i in 0 .. 3 { push(fs, || i); }
    for f in fs { emit(showInt(f())); }
    print("");
}
''', True)
    add('control', 'while_cond_order', '''@module main
fn main() {
    var i = 0;
    while i < 3 { emit(showInt(i)); i = i + 1; }
    print("");
}
''')
    add('control', 'match_stmt_unit_arms', '''@module main
fn main() {
    match 1 {
        1 -> print("one"),
        _ -> { emit("other"); print(""); }
    }
}
''')
    add('control', 'if_else_chain', '''@module main
fn grade(n: Int) -> Str {
    if n > 90 { "a" } else if n > 80 { "b" } else { "c" }
}
fn main() { print(grade(95) ++ grade(85) ++ grade(10)); }
''', True)
    add('control', 'block_value', '''@module main
fn main() {
    let x = if true { let y = 2; y * 3 } else { 0 };
    print(showInt(x));
}
''', True)
    add('control', 'diverging_arms', '''@module main
fn f(n: Int) -> Int {
    let v = match n {
        0 -> { return -1; },
        _ -> 5,
    };
    v
}
fn main() { print(showInt(f(0)) ++ " " ++ showInt(f(1))); }
''')
    add('check', 'unit_fn_trailing', '''@module main
fn f() { 5 }
fn main() { f(); }
''')
    add('check', 'return_unit_value', '''@module main
fn g() { emit("g"); }
fn f() { return g(); }
fn main() { f(); print(" done"); }
''')
    add('check', 'return_value_in_unit', '''@module main
fn f() { return 1; }
fn main() { f(); }
''')
    add('closure', 'nested_fn_type', '''@module main
fn apply(f: fn(Int) -> fn(Int) -> Int, x: Int) -> Int { (f(x))(2) }
fn mk(a: Int) -> fn(Int) -> Int { |b: Int| a * b }
fn main() { print(showInt(apply(|a: Int| mk(a), 21))); }
''')
    add('maplib', 'map_of_list', '''@module main
fn main() {
    var m: #[Str: [Int]] = mapNew();
    m["a"] = [1];
    push(m["a"], 2);
    print(showInt(listLen(m["a"])));
    print(showInt(listLen(mapGetOr(m, "b", []))));
}
''', True)
    add('maplib', 'char_key_map', '''@module main
fn main() {
    var m = #['a': 1];
    m['b'] = 2;
    for k in keysOf(m) { emit(showChar(k)); }
    print("");
    print(showBool(mapHas(m, 'a')));
}
''')
    add('maplib', 'bool_key_map', '''@module main
fn main() {
    var m = #[true: 1];
    m[false] = 0;
    print(showInt(mapLen(m)) ++ showInt(m[true]) ++ showInt(m[false]));
}
''')
    add('pattern', 'enum_payload_8', '''@module main
enum E { V(Int, Int, Int, Int, Int, Int, Int, Int) }
fn main() {
    match V(1, 2, 3, 4, 5, 6, 7, 8) {
        V(a, b, c, d, e, f, g, h) -> print(showInt(a + h)),
    }
}
''', True)
    add('pattern', 'struct_pattern_rest', '''@module main
struct S { a: Int, b: Int, c: Int }
fn main() {
    let s = S.{ a: 1, b: 2, c: 3 };
    let S.{ b, .. } = s;
    print(showInt(b));
    match s { S.{ a: 1, .. } -> print("one"), _ -> print("other") }
}
''', True)
    add('pattern', 'list_pattern_rest_bind', '''@module main
fn main() {
    match [1, 2, 3] {
        [a, ..rest] -> print(showInt(a) ++ ":" ++ showInt(listLen(rest))),
        [] -> print("empty"),
    }
}
''', True)
    add('module', 'qualified_variant', '''@module main
use o;
fn main() {
    match o::mk() { o::Red -> print("red"), o::Blue -> print("blue") }
}
@module o
pub enum Colour { Red, Blue }
pub fn mk() -> Colour { Blue }
''', True)
    add('trait', 'method_on_imported_struct', '''@module main
use o;
trait Area { fn area(self) -> Int; }
impl Area for o::Box { fn area(self) -> Int { self.w * self.h } }
fn main() { print(showInt(o::mk(3, 4).area())); }
@module o
pub struct Box { w: Int, h: Int }
pub fn mk(w: Int, h: Int) -> Box { Box.{ w: w, h: h } }
''')
    add('trait', 'trait_visible_via_import', '''@module main
use o;
fn main() { print(showInt(3.tag())); }
@module o
pub trait Tag { fn tag(self) -> Int { 7 } }
impl Tag for Int {}
''')
    add('trait', 'trait_not_visible', '''@module main
use o;
fn main() { print(showInt(3.tag())); }
@module o
trait Tag { fn tag(self) -> Int { 7 } }
impl Tag for Int {}
''')

def hand_5():
    """Hand-written: `Self` in signatures, cross-module traits, misc semantics."""
    add('trait', 'self_in_sig', '''@module main
trait Add2 {
    fn plus(self, other: Self) -> Self;
    fn twice(self) -> Self { self.plus(self) }
}
impl Add2 for Int { fn plus(self, other: Int) -> Int { self + other } }
impl Add2 for Str { fn plus(self, other: Str) -> Str { self ++ other } }
fn main() {
    print(showInt(3.plus(4)));
    print(showInt(3.twice()));
    print("ab".twice());
}
''', True)
    add('trait', 'self_sig_mismatch', '''@module main
trait T { fn f(self, o: Self) -> Self; }
impl T for Int { fn f(self, o: Int) -> Str { "x" } }
fn main() {}
''')
    add('generic', 'generic_struct_impl', '''@module main
struct Pair<A, B> { l: A, r: B }
trait Show { fn show(self) -> Str; }
impl Show for Int { fn show(self) -> Str { showInt(self) } }
impl Show for Str { fn show(self) -> Str { self } }
impl<A: Show, B: Show> Show for Pair<A, B> {
    fn show(self) -> Str { "(" ++ self.l.show() ++ "," ++ self.r.show() ++ ")" }
}
fn main() {
    print(Pair.{ l: 1, r: "x" }.show());
    print(Pair.{ l: Pair.{ l: 1, r: 2 }, r: "y" }.show());
}
''', True)
    add('generic', 'bound_fails_nested', '''@module main
struct Pair<A, B> { l: A, r: B }
trait Show { fn show(self) -> Str; }
impl Show for Int { fn show(self) -> Str { showInt(self) } }
impl<A: Show, B: Show> Show for Pair<A, B> {
    fn show(self) -> Str { "(" ++ self.l.show() ++ "," ++ self.r.show() ++ ")" }
}
fn main() { print(Pair.{ l: 1, r: 1.5 }.show()); }
''')
    add('trait', 'cross_module_trait', '''@module main
use o;
fn main() { print(showInt(3.go())); print(showInt(o::call(4))); }
@module o
trait Go { fn go(self) -> Int; }
pub fn call(x: Int) -> Int { x.go() }
@module impls
use o;
impl o::Go for Int { fn go(self) -> Int { self * 10 } }
''')
    add('trait', 'cross_module_trait2', '''@module main
use o;
use o as q;
fn main() { print(showInt(3.go())); print(showInt(o::call(4))); }
@module o
pub trait Go { fn go(self) -> Int; }
pub fn call(x: Int) -> Int { x.go() }
@module impls
use o;
impl o::Go for Int { fn go(self) -> Int { self * 10 } }
''')
    add('control', 'for_over_str', '''@module main
fn main() {
    var n = 0;
    for ch in "héllo" { if isAlpha(ch) { n = n + 1; } }
    print(showInt(n));
    for ch in "ab" { emit(showChar(ch)); }
    print("");
}
''', True)
    add('pattern', 'nested_struct_match', '''@module main
struct P { x: Int, y: Int }
enum Shape { Dot(P), Line(P, P) }
fn f(s: Shape) -> Int {
    match s {
        Dot(P.{ x: 0, y: y }) -> y,
        Dot(P.{ x: x, .. }) -> x,
        Line(P.{ x: a, y: _ }, P.{ x: b, y: _ }) -> a + b,
    }
}
fn main() {
    print(showInt(f(Dot(P.{ x: 0, y: 5 }))));
    print(showInt(f(Dot(P.{ x: 3, y: 5 }))));
    print(showInt(f(Line(P.{ x: 1, y: 0 }, P.{ x: 2, y: 0 }))));
}
''')
    add('intlib', 'int_mod_edge', '''@module main
fn main() {
    print(showInt(intMin() % -1));
    print(showInt(intMin() / 1));
    print(showInt(0 / 5) ++ " " ++ showInt(0 % 5));
    print(showInt(5 / 0));
}
''', True)
    add('runtime', 'mod_zero', '''@module main
fn main() { print(showInt(5 % 0)); }
''', True)
    add('runtime', 'neg_shift', '''@module main
fn main() { print(showInt(1 << -1)); }
''')
    add('intlib', 'bit_precedence', '''@module main
fn main() {
    print(showBool(1 & 3 == 1));
    print(showBool(1 | 2 == 3));
    print(showInt(1 + 2 * 3));
    print(showInt(-2 * 3));
    print(showInt(~0 & 15));
    print(showBool(!(1 == 2)));
    print(showInt(1 << 2 + 1));
}
''', True)
    add('value', 'tuple_index_fns', '''@module main
fn main() {
    let t = (1, "a");
    print(showInt(fst(t)) ++ snd(t));
    let (a, b) = t;
    print(showInt(a) ++ b);
    let big = (1, 2, 3);
    let (x, y, z) = big;
    print(showInt(x + y + z));
}
''', True)
    add('value', 'list_identity', '''@module main
fn add(xs: [Int]) { push(xs, 1); }
fn main() {
    let a = [0];
    let b = a;
    add(a);
    print(showInt(listLen(b)));
    let c = listCopy(a);
    add(a);
    print(showInt(listLen(c)) ++ showInt(listLen(a)));
}
''', True)
    add('value', 'map_identity', '''@module main
fn main() {
    let m = #[1: 1];
    let n = m;
    n[2] = 2;
    print(showInt(mapLen(m)));
    let p = mapCopy(m);
    mapClear(m);
    print(showInt(mapLen(p)) ++ showInt(mapLen(m)));
}
''')
    add('value', 'str_immutable_concat', '''@module main
fn main() {
    let a = "x";
    let b = a ++ "y";
    print(a ++ "|" ++ b);
    let xs = [1];
    let ys = xs ++ [2];
    print(showInt(listLen(xs)) ++ showInt(listLen(ys)));
}
''')
    add('pattern', 'guard_sees_bindings', '''@module main
fn main() {
    match (3, 4) {
        (a, b) when a > b -> print("gt"),
        (a, b) when a < b -> print("lt"),
        _ -> print("eq"),
    }
}
''')
    add('pattern', 'match_on_str', '''@module main
fn f(s: Str) -> Int {
    match s { "a" -> 1, "bb" -> 2, _ -> 0 }
}
fn main() { print(showInt(f("a") + f("bb") + f("c"))); }
''', True)
    add('pattern', 'empty_struct', '''@module main
struct E {}
fn main() { let e = E.{}; match e { E.{} -> print("ok") } }
''', True)
    add('exhaust', 'empty_enum_match', '''@module main
enum Void {}
fn f(v: Void) -> Int { match v { _ -> 0 } }
fn main() { print("ok"); }
''')
    add('program', 'recursive_enum', '''@module main
enum Tree { Leaf(Int), Node(Tree, Tree) }
fn sum(t: Tree) -> Int {
    match t { Leaf(n) -> n, Node(l, r) -> sum(l) + sum(r) }
}
fn main() { print(showInt(sum(Node(Leaf(1), Node(Leaf(2), Leaf(3)))))); }
''', True)
    add('program', 'mutual_recursion', '''@module main
fn even(n: Int) -> Bool { if n == 0 { true } else { odd(n - 1) } }
fn odd(n: Int) -> Bool { if n == 0 { false } else { even(n - 1) } }
fn main() { print(showBool(even(10)) ++ showBool(odd(10))); }
''', True)
    add('item', 'forward_ref_types', '''@module main
struct A { b: Option<B> }
struct B { a: Option<A> }
fn main() {
    let a = A.{ b: Some(B.{ a: None }) };
    print(showBool(isSome(a.b)));
}
''')
    add('check', 'shadow_in_block', '''@module main
fn main() {
    let x = 1;
    { let x = 2; print(showInt(x)); }
    print(showInt(x));
    let x = 3;
    print(showInt(x));
}
''')
    add('check', 'let_shadow_same_scope', '''@module main
fn main() {
    let x = 1;
    let x = x + 1;
    print(showInt(x));
}
''')

def hand_6():
    """Hand-written: lexer and parser details: commas, CRLF, comments, odd tokens."""
    add('parse', 'trailing_commas', '''@module main
struct S<A,> { a: A, }
enum E<T,> { V(T,), W, }
fn f<T,>(a: T,) -> T { a }
trait Tr { fn m(self, x: Int,) -> Int; }
impl<T,> Tr for E<T,> { fn m(self, x: Int,) -> Int { x } }
fn main() {
    let s = S.{ a: 1, };
    print(showInt(f(s.a,)));
    let xs = [1, 2,];
    let m = #[1: 2,];
    let t = (1, 2,);
    print(showInt(listLen(xs) + mapLen(m) + fst(t)));
    let g = |a: Int, b: Int,| a + b;
    print(showInt(g(1, 2,)));
    print(showInt(V(3).m(4)));
    let w: E<Int> = W;
    match w { V(n,) -> print(showInt(n)), W -> print("w"), }
}
''', True)
    add('module', 'crlf', '''@module main
fn main() {
    print("ok");
}
''', True)
    add('module', 'no_final_newline', '''@module main
fn main() { print("ok"); }''')
    add('module', 'empty_module_body', '''@module a
@module main
fn main() { print("ok"); }
''')
    add('lex', 'comment_at_eof', '''@module main
fn main() { print("ok"); }
// end''')
    add('lex', 'block_comment_eof', '''@module main
fn main() { print("ok"); }
/* x */''')
    add('lex', 'non_ascii_ident', '''@module main
fn main() { let é = 1; }
''')
    add('parse', 'wildcard_expr', '''@module main
fn main() { let x = _; }
''')
    add('lex', 'underscore_ident', '''@module main
fn main() { let _x = 1; let x_ = _x; print(showInt(x_)); }
''')
    add('lex', 'long_ident', '''@module main
fn main() { let aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa = 1; }
''')
    add('lex', 'long_ident_ok', '''@module main
fn main() { let aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa = 1; print(showInt(aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa)); }
''', True)
    add('lex', 'int_seps', '''@module main
fn main() { print(showInt(1_000_000 + 0x_f)); }
''')
    add('lex', 'int_seps_ok', '''@module main
fn main() { print(showInt(1_000 + 0xff_ff + 0b1010_1010)); }
''')
    add('lex', 'float_dot', '''@module main
fn main() { print(showInt(1.0)); }
''')
    add('lex', 'float_forms', '''@module main
fn main() {
    print(showFloat(1e3));
    print(showFloat(1.5E-2));
    print(showFloat(1_0.2_5));
    print(showFloatAt(0.0, 0));
}
''', True)
    add('lex', 'range_dots', '''@module main
fn main() { for i in 0..3 { emit(showInt(i)); } print(""); }
''')
    add('parse', 'zero_arg_lambda_block', '''@module main
fn main() {
    let f = || -> Int { 7 };
    print(showInt(f()));
    let g = | | 8;
    print(showInt(g()));
}
''')
    add('parse', 'lambda_block_no_ret', '''@module main
fn main() {
    let f = |x: Int| { emit("c"); x + 1 };
    print(showInt(f(1)));
}
''')
    add('parse', 'match_block_arm_no_comma', '''@module main
fn main() {
    match 1 {
        1 -> { print("one") }
        _ -> print("other"),
    }
}
''', True)
    add('parse', 'match_missing_comma', '''@module main
fn main() {
    match 1 {
        1 -> print("one")
        _ -> print("other"),
    }
}
''')
    add('parse', 'if_stmt_no_semi', '''@module main
fn main() {
    if true { print("a"); }
    print("b");
}
''')
    add('parse', 'nested_generic_type', '''@module main
fn f(m: #[Str: [Option<Int>]]) -> Int { mapLen(m) }
fn main() { print(showInt(f(#["a": [Some(1), None]]))); }
''')
    add('lex', 'hash_not_bracket', '''@module main
fn main() { let x = # 1; }
''')
    add('module', 'empty_input_dup', '''@module main
''')
    add('module', 'at_in_middle', '''@module main
fn main() {}
@ oops
''')
    add('module', 'module_keyword_name', '''@module if
fn main() {}
''')
    add('module', 'module_underscore', '''@module _
fn main() {}
''')

def hand_7():
    """Hand-written: exhaustiveness and reachability with mixed columns."""
    add('exhaust', 'tuple_list_exh', '''@module main
fn f(xs: [Int], b: Bool) -> Int {
    match (xs, b) {
        ([], true) -> 1,
        ([], false) -> 2,
        ([_, ..], _) -> 3,
    }
}
fn main() { print("ok"); }
''', True)
    add('exhaust', 'tuple_list_nonexh', '''@module main
fn f(xs: [Int], b: Bool) -> Int {
    match (xs, b) {
        ([], true) -> 1,
        ([_, ..], _) -> 3,
    }
}
fn main() { print("ok"); }
''')
    add('exhaust', 'nested_list', '''@module main
fn f(xss: [[Int]]) -> Int {
    match xss {
        [[a], ..] -> a,
        [[], ..] -> 0,
        [] -> -1,
        [_, ..] -> -2,
    }
}
fn main() { print("ok"); }
''', True)
    add('exhaust', 'option_list_exh', '''@module main
fn f(o: Option<[Int]>) -> Int {
    match o {
        Some([]) -> 0,
        Some([_, ..]) -> 1,
        None -> -1,
    }
}
fn main() { print("ok"); }
''')
    add('exhaust', 'list_unreach_order', '''@module main
fn f(xs: [Int]) -> Int {
    match xs {
        [a, ..] -> a,
        [_, _] -> 2,
        [] -> 0,
    }
}
fn main() { print("ok"); }
''', True)
    add('exhaust', 'list_reach_order', '''@module main
fn f(xs: [Int]) -> Int {
    match xs {
        [_, _] -> 2,
        [a, ..] -> a,
        [] -> 0,
    }
}
fn main() { print("ok"); }
''')
    add('exhaust', 'struct_rest_exh', '''@module main
struct P { a: Int, b: Str }
fn f(p: P) -> Int {
    match p { P.{ a, .. } -> a }
}
fn main() { print("ok"); }
''')
    add('exhaust', 'nested_option_nonexh', '''@module main
fn f(o: Option<Option<Int>>) -> Int {
    match o {
        Some(Some(n)) -> n,
        None -> 0,
    }
}
fn main() { print("ok"); }
''')
    add('exhaust', 'guard_then_cover', '''@module main
fn f(n: Int) -> Int {
    match n {
        0 when n > 0 -> 1,
        0 -> 2,
        _ -> 3,
    }
}
fn main() { print("ok"); }
''', True)
    add('exhaust', 'guard_only_nonexh', '''@module main
fn f(b: Bool) -> Int {
    match b {
        true -> 1,
        false when b -> 2,
    }
}
fn main() { print("ok"); }
''')
    add('exhaust', 'str_match_exh', '''@module main
fn f(s: Str) -> Int {
    match s { "a" -> 1, _ -> 0 }
}
fn main() { print("ok"); }
''')
    add('exhaust', 'char_match_nonexh', '''@module main
fn f(ch: Char) -> Int {
    match ch { 'a' -> 1, 'b' -> 2 }
}
fn main() { print("ok"); }
''')
    add('exhaust', 'bool_pair_exh', '''@module main
fn f(p: (Bool, Bool)) -> Int {
    match p {
        (true, _) -> 1,
        (_, true) -> 2,
        (false, false) -> 3,
    }
}
fn main() { print("ok"); }
''', True)
    add('exhaust', 'bool_pair_unreach', '''@module main
fn f(p: (Bool, Bool)) -> Int {
    match p {
        (true, _) -> 1,
        (false, _) -> 2,
        (_, true) -> 3,
    }
}
fn main() { print("ok"); }
''')
    add('exhaust', 'deep_rest_bind', '''@module main
fn f(xs: [[Int]]) -> Int {
    match xs {
        [[_, ..r], ..] -> listLen(r),
        _ -> 0,
    }
}
fn main() { print("ok"); }
''')
    add('exhaust', 'enum_nested_exh', '''@module main
enum B { B1, B2(Int) }
enum T { A(B), C }
fn f(t: T) -> Int {
    match t {
        A(B1) -> 1,
        A(B2(n)) -> n,
        C -> 3,
    }
}
fn main() { print("ok"); }
''', True)
    add('exhaust', 'enum_nested_nonexh', '''@module main
enum B { B1, B2(Int) }
enum T { A(B), C }
fn f(t: T) -> Int {
    match t {
        A(B1) -> 1,
        C -> 3,
    }
}
fn main() { print("ok"); }
''')
    add('exhaust', 'unit_in_tuple', '''@module main
fn f(p: (Unit, Bool)) -> Int {
    match p { (_, true) -> 1, (_, false) -> 0 }
}
fn main() { print("ok"); }
''')
    add('exhaust', 'wild_after_all_variants', '''@module main
fn f(b: Bool) -> Int {
    match b { true -> 1, false -> 0, _ -> 2 }
}
fn main() { print("ok"); }
''')


def hand_8():
    """Hand-written: a second, differently placed case for each error kind
    whose first case is public, so the hidden set covers every kind too."""
    add('type', 'arity_type_nested_alias', '''@module main
use box as b;
fn wrap(x: Int) -> [Option<b::Box<Int>>] { [None] }
fn main() { print(showInt(listLen(wrap(1)))); }
@module box
pub struct Box<T, U> { a: T, b: U }
''', False, expect='error arity-type')
    add('trait', 'bad_impl_head_tuple', '''@module main
trait Pretty { fn pretty(self) -> Str; }
impl Pretty for Int { fn pretty(self) -> Str { showInt(self) } }
impl<A, B> Pretty for (A, B) { fn pretty(self) -> Str { "pair" } }
fn main() { print(1.pretty()); }
''', False, expect='error bad-impl-head')
    add('pattern', 'bad_pattern_negative_float_nested', '''@module main
fn f(p: (Int, Option<Float>)) -> Int {
    match p {
        (0, None) -> 0,
        (_, Some(-2.5)) -> 1,
        _ -> 2,
    }
}
fn main() { print(showInt(f((1, Some(2.5))))); }
''', False, expect='error bad-pattern')
    add('trait', 'builtin_trait_impl_ord_generic', '''@module main
struct W<T> { v: T }
trait Size { fn size(self) -> Int; }
impl<T> Size for W<T> { fn size(self) -> Int { 1 } }
impl<T> Ord for W<T> { }
fn main() { print(showInt(W.{ v: 1 }.size())); }
''', False, expect='error builtin-trait-impl')
    add('check', 'dup_field_in_pattern', '''@module main
struct P { x: Int, y: Int }
fn main() {
    let p = P.{ x: 1, y: 2 };
    let P.{ x: a, y: b, x: c } = p;
    print(showInt(a + b + c));
}
''', False, expect='error dup-field')
    add('trait', 'dup_impl_generic_heads', '''@module main
use other;
struct W<T> { v: T }
trait Count { fn count(self) -> Int; }
impl<T> Count for [T] { fn count(self) -> Int { listLen(self) } }
impl<T> Count for W<T> { fn count(self) -> Int { 1 } }
impl Count for Str { fn count(self) -> Int { strLen(self) } }
impl<U> Count for W<U> { fn count(self) -> Int { 0 } }
fn main() { print(showInt([1, 2].count())); }
@module other
pub fn x() -> Int { 1 }
''', False, expect='error dup-impl')
    add('trait', 'extra_method_after_ok_ones', '''@module main
trait Shape {
    fn area(self) -> Int;
    fn name(self) -> Str { "shape" }
}
struct Sq { s: Int }
impl Shape for Sq {
    fn area(self) -> Int { self.s * self.s }
    fn name(self) -> Str { "sq" }
    fn perimeter(self) -> Int { 4 * self.s }
}
fn main() { print(showInt(Sq.{ s: 2 }.area())); }
''', False, expect='error extra-method')
    add('trait', 'missing_method_second_of_three', '''@module main
use shapes;
impl shapes::Shape for Int {
    fn area(self) -> Int { self }
    fn corners(self) -> Int { 4 }
}
fn main() { print(showInt(3.area())); }
@module shapes
pub trait Shape {
    fn area(self) -> Int;
    fn name(self) -> Str;
    fn corners(self) -> Int;
    fn label(self) -> Str { "x" }
}
''', False, expect='error missing-method')
    add('check', 'not_callable_field_value', '''@module main
struct Cfg { limit: Int, f: fn(Int) -> Int }
fn main() {
    let c = Cfg.{ limit: 3, f: |x: Int| x + 1 };
    print(showInt((c.f)(1)));
    let n = c.limit;
    print(showInt(n(2)));
}
''', False, expect='error not-callable')
    add('check', 'not_indexable_tuple', '''@module main
fn main() {
    let t = (1, 2);
    let xs = [t, t];
    print(showInt(fst(xs[0])));
    print(showInt(xs[1][0]));
}
''', False, expect='error not-indexable')
    add('value', 'not_ord_list', '''@module main
fn main() {
    let a = [1, 2] < [1, 3];
    print(showBool(a));
    let m = #[1: 2];
    print(showBool(m <= m));
}
''', False, expect='error not-ord')
    add('check', 'unknown_field_generic_struct', '''@module main
struct Pair<A, B> { left: A, right: B }
fn swap<A, B>(p: Pair<A, B>) -> Pair<B, A> { Pair.{ left: p.right, right: p.lefft } }
fn main() { print(showInt(swap(Pair.{ left: 1, right: "a" }).right)); }
''', False, expect='error unknown-field')
    add('trait', 'unknown_trait_in_bound', '''@module main
use util;
fn show<T: util::Showable>(x: T) -> Str { "?" }
fn main() { print(show(1)); }
@module util
pub trait Show { fn show(self) -> Str; }
''', False, expect='error unknown-trait')
    add('type', 'unknown_type_in_lambda_annotation', '''@module main
fn main() {
    let f = |x: Int, y: Strng| x;
    print(showInt(f(1, "a")));
}
''', False, expect='error unknown-type')
    add('trait', 'unused_param_second', '''@module main
trait Name { fn name(self) -> Str; }
enum Two<A> { One(A), Zero }
impl<A, B> Name for Two<A> { fn name(self) -> Str { "two" } }
fn main() { let z: Two<Int> = Zero; print(z.name()); }
''', False, expect='error unused-param')


def spec_examples():
    """The worked examples of SPEC.md section 17, extracted from the spec."""
    text = open(SPEC, encoding='utf-8').read()
    sec = text.split('## 17. Worked examples')[1].split('## 18.')[0]
    chunks = re.split(r'\n### Example ', sec)[1:]
    n = 0
    for chunk in chunks:
        num = int(chunk.split(' ')[0])
        if num == 17:
            # Ten mini programs, each with its single expected line.
            pairs = re.findall(r'\n```\n(.*?)\n```\n→ `(.*?)`\n', chunk, re.S)
            assert len(pairs) == 10, len(pairs)
            for i, (prog, _line) in enumerate(pairs, 1):
                add('spec', 'diag_%02d' % i, prog + '\n', True if i <= 5 else None)
            n += len(pairs)
            continue
        blocks = re.findall(r'\n```\n(.*?)\n```\n', chunk, re.S)
        assert len(blocks) >= 2, num
        add('spec', 'example_%02d' % num, blocks[0] + '\n', True)
        n += 1
    assert n == 26, n


# --- library sweeps -------------------------------------------------------
#
# Each sweep entry is one statement of a `main` body.  The helpers below are
# prepended to every sweep program so the entries stay short, and every entry
# prints exactly one line, so a sweep's expected output is a per-call
# transcript of the library.

SWEEP_HELPERS = '''fn si(x: Int) -> Str { showInt(x) }
fn sf(x: Float) -> Str { showFloat(x) }
fn sb(b: Bool) -> Str { showBool(b) }
fn sc(c: Char) -> Str { showChar(c) }
fn so(o: Option<Int>) -> Str { if isNone(o) { "none" } else { showInt(unwrap(o)) } }
fn sof(o: Option<Float>) -> Str { if isNone(o) { "none" } else { showFloat(unwrap(o)) } }
fn sl(xs: [Int]) -> Str { "[" ++ strJoin(listMap(xs, |v| showInt(v)), ",") ++ "]" }
fn ss(xs: [Str]) -> Str { "[" ++ strJoin(xs, "|") ++ "]" }
fn sp(ps: [(Str, Int)]) -> Str {
    strJoin(listMap(ps, |p| fst(p) ++ "=" ++ showInt(snd(p))), ",")
}
'''

SWEEP_INT = [
    'print(si(intMin()) ++ " " ++ si(intMax()));',
    'print(si(absI(-5)) ++ " " ++ si(absI(0)) ++ " " ++ si(absI(intMin())));',
    'print(si(minI(3, -3)) ++ " " ++ si(maxI(3, -3)) ++ " " ++ si(minI(intMin(), intMax())));',
    'print(si(signI(-9)) ++ si(signI(0)) ++ si(signI(9)));',
    'print(si(cmpI(1, 2)) ++ si(cmpI(2, 2)) ++ si(cmpI(3, 2)));',
    'print(si(7 / 2) ++ " " ++ si(-7 / 2) ++ " " ++ si(7 / -2) ++ " " ++ si(-7 / -2));',
    'print(si(7 % 2) ++ " " ++ si(-7 % 2) ++ " " ++ si(7 % -2) ++ " " ++ si(-7 % -2));',
    'print(si(divFloor(7, 2)) ++ " " ++ si(divFloor(-7, 2)) ++ " " ++ si(divFloor(7, -2)) ++ " " ++ si(divFloor(-7, -2)));',
    'print(si(modFloor(7, 2)) ++ " " ++ si(modFloor(-7, 2)) ++ " " ++ si(modFloor(7, -2)) ++ " " ++ si(modFloor(-7, -2)));',
    'print(si(divFloor(intMin(), -1)) ++ " " ++ si(modFloor(intMin(), -1)));',
    'print(si(powI(2, 10)) ++ " " ++ si(powI(-3, 3)) ++ " " ++ si(powI(5, 0)) ++ " " ++ si(powI(2, 64)));',
    'print(si(gcdI(12, 18)) ++ " " ++ si(gcdI(-12, 18)) ++ " " ++ si(gcdI(0, 7)) ++ " " ++ si(gcdI(0, 0)));',
    'print(si(popCount(0)) ++ " " ++ si(popCount(255)) ++ " " ++ si(popCount(-1)) ++ " " ++ si(popCount(intMin())));',
    'print(si(clz(0)) ++ " " ++ si(clz(1)) ++ " " ++ si(clz(-1)) ++ " " ++ si(ctz(0)) ++ " " ++ si(ctz(8)) ++ " " ++ si(ctz(intMin())));',
    'print(sf(toFloat(0)) ++ " " ++ sf(toFloat(-1)) ++ " " ++ sf(toFloat(intMax())));',
    'print(showInt(0) ++ " " ++ showInt(-0) ++ " " ++ showInt(intMin()));',
    'print(showIntRadix(255, 16) ++ " " ++ showIntRadix(255, 2) ++ " " ++ showIntRadix(-1, 16) ++ " " ++ showIntRadix(0, 7));',
    'print(showIntRadix(intMin(), 2));',
    'print(showIntRadix(1295, 36) ++ " " ++ showIntRadix(-255, 36));',
    'print(so(parseInt("0")) ++ " " ++ so(parseInt("-42")) ++ " " ++ so(parseInt("+42")) ++ " " ++ so(parseInt("007")));',
    'print(so(parseInt("")) ++ " " ++ so(parseInt("-")) ++ " " ++ so(parseInt("1 ")) ++ " " ++ so(parseInt("1_0")) ++ " " ++ so(parseInt("0x1")));',
    'print(so(parseInt("9223372036854775807")) ++ " " ++ so(parseInt("9223372036854775808")) ++ " " ++ so(parseInt("-9223372036854775808")));',
    'print(so(parseIntRadix("ff", 16)) ++ " " ++ so(parseIntRadix("FF", 16)) ++ " " ++ so(parseIntRadix("102", 2)) ++ " " ++ so(parseIntRadix("-7f", 16)));',
    'print(si(1 << 0) ++ " " ++ si(1 << 62) ++ " " ++ si(-1 >> 1) ++ " " ++ si(intMin() >> 63) ++ " " ++ si(255 >> 4));',
    'print(si(12 & 10) ++ " " ++ si(12 | 10) ++ " " ++ si(12 ^ 10) ++ " " ++ si(~12));',
    'print(si(intMax() + 1) ++ " " ++ si(intMin() - 1) ++ " " ++ si(intMax() * 3));',
]

SWEEP_FLOAT = [
    'print(sf(sqrtF(2.0)) ++ " " ++ sf(sqrtF(0.0)) ++ " " ++ sf(sqrtF(-0.0)) ++ " " ++ sb(isNanF(sqrtF(-4.0))));',
    'print(sf(absF(-2.5)) ++ " " ++ sf(absF(-0.0)) ++ " " ++ sb(isNanF(absF(nanF()))));',
    'print(sf(floorF(2.5)) ++ " " ++ sf(floorF(-2.5)) ++ " " ++ sf(ceilF(2.5)) ++ " " ++ sf(ceilF(-2.5)));',
    'print(sf(truncF(2.9)) ++ " " ++ sf(truncF(-2.9)) ++ " " ++ sf(roundF(2.5)) ++ " " ++ sf(roundF(-2.5)) ++ " " ++ sf(roundF(0.49)));',
    'print(sf(minF(1.0, 2.0)) ++ " " ++ sf(maxF(1.0, 2.0)) ++ " " ++ sf(minF(-0.0, 0.0)) ++ " " ++ sf(minF(0.0, -0.0)));',
    'print(sf(minF(nanF(), 1.0)) ++ " " ++ sb(isNanF(maxF(nanF(), 1.0))) ++ " " ++ sb(isNanF(minF(1.0, nanF()))));',
    'print(sf(fmodF(5.5, 2.0)) ++ " " ++ sf(fmodF(-5.5, 2.0)) ++ " " ++ sf(fmodF(5.5, -2.0)) ++ " " ++ sb(isNanF(fmodF(1.0, 0.0))));',
    'print(sf(powF(2.0, 10)) ++ " " ++ sf(powF(2.0, 0)) ++ " " ++ sf(powF(2.0, -2)) ++ " " ++ sf(powF(1.1, 3)));',
    'print(sf(powF(0.0, 0)) ++ " " ++ sf(powF(-2.0, 3)) ++ " " ++ sf(powF(10.0, 20)));',
    'print(sb(isNanF(nanF())) ++ sb(isNanF(1.0)) ++ sb(isInfF(infF())) ++ sb(isInfF(-infF())) ++ sb(isInfF(0.0)));',
    'print(si(cmpF(1.0, 2.0)) ++ si(cmpF(2.0, 2.0)) ++ si(cmpF(-0.0, 0.0)) ++ si(cmpF(nanF(), nanF())) ++ si(cmpF(nanF(), 0.0)) ++ si(cmpF(0.0, nanF())));',
    'print(si(truncToInt(2.9)) ++ " " ++ si(truncToInt(-2.9)) ++ " " ++ si(truncToInt(0.0)) ++ " " ++ si(truncToInt(-0.5)));',
    'print(showFloat(1.0) ++ " " ++ showFloat(0.1) ++ " " ++ showFloat(2.0 / 3.0) ++ " " ++ showFloat(-0.0));',
    'print(showFloatAt(2.5, 0) ++ " " ++ showFloatAt(3.5, 0) ++ " " ++ showFloatAt(0.5, 0) ++ " " ++ showFloatAt(-2.5, 0));',
    'print(showFloatAt(1.0 / 3.0, 10) ++ " " ++ showFloatAt(0.1 + 0.2, 17));',
    'print(showFloatAt(2.675, 2) ++ " " ++ showFloatAt(1e21, 2) ++ " " ++ showFloatAt(nanF(), 3) ++ " " ++ showFloatAt(-1.0 / 0.0, 3));',
    'print(showFloatAt(1.5, 1) ++ " " ++ showFloatAt(0.0, 17) ++ " " ++ showFloatAt(1234.5678, 3));',
    'print(si(floatBits(1.0)) ++ " " ++ si(floatBits(-0.0)) ++ " " ++ si(floatBits(nanF())));',
    'print(sf(floatFromBits(0)) ++ " " ++ sf(floatFromBits(4607182418800017408)) ++ " " ++ sb(isNanF(floatFromBits(-1))));',
    'print(sof(parseFloat("1.5")) ++ " " ++ sof(parseFloat("-2")) ++ " " ++ sof(parseFloat(".5")) ++ " " ++ sof(parseFloat("12.")));',
    'print(sof(parseFloat("1e3")) ++ " " ++ sof(parseFloat("1E-2")) ++ " " ++ sof(parseFloat("+0.0")));',
    'print(sof(parseFloat("")) ++ " " ++ sof(parseFloat("inf")) ++ " " ++ sof(parseFloat("1_0")) ++ " " ++ sof(parseFloat(" 1")) ++ " " ++ sof(parseFloat("1e")));',
    'print(sb(unwrapOr(parseFloat("1e400"), 0.0) == infF()) ++ " " ++ sf(unwrapOr(parseFloat("1e-400"), 1.0)));',
    'print(sf(infF()) ++ " " ++ sf(-infF()) ++ " " ++ sf(nanF()) ++ " " ++ showFloatAt(piF(), 15));',
    'print(sf(1.0 / 0.0) ++ " " ++ sf(-1.0 / 0.0) ++ " " ++ sf(0.0 / 0.0) ++ " " ++ sf(infF() - infF()));',
    'print(sf(0.1 + 0.2) ++ " " ++ sf(1.0e308 * 10.0) ++ " " ++ sf(5.0e-324 / 2.0));',
]

SWEEP_CHAR = [
    'print(sb(true) ++ " " ++ sb(false) ++ " " ++ sb(1 == 1));',
    'print(si(ord(\'a\')) ++ " " ++ si(ord(\'\\u{0}\')) ++ " " ++ si(ord(\'\\u{10ffff}\')) ++ " " ++ si(ord(\'é\')));',
    'print(sc(chr(97)) ++ " " ++ sc(chr(0x10ffff)) ++ " " ++ si(ord(chr(55295))) ++ " " ++ si(ord(chr(57344))));',
    'print(sb(isDigit(\'5\')) ++ sb(isDigit(\'a\')) ++ sb(isAlpha(\'Z\')) ++ sb(isAlpha(\'é\')) ++ sb(isAlnum(\'_\')) ++ sb(isAlnum(\'9\')));',
    'print(sb(isSpace(\' \')) ++ sb(isSpace(\'\\t\')) ++ sb(isSpace(\'\\n\')) ++ sb(isSpace(\'\\u{b}\')) ++ sb(isSpace(\'\\u{c}\')) ++ sb(isSpace(\'\\r\')) ++ sb(isSpace(\'x\')));',
    'print(sb(isUpper(\'A\')) ++ sb(isUpper(\'a\')) ++ sb(isLower(\'a\')) ++ sb(isLower(\'A\')));',
    'print(sc(toUpperC(\'a\')) ++ sc(toUpperC(\'A\')) ++ sc(toUpperC(\'1\')) ++ sc(toLowerC(\'Z\')) ++ sc(toLowerC(\'z\')) ++ sc(toUpperC(\'é\')));',
    'print(si(cmpC(\'a\', \'b\')) ++ si(cmpC(\'b\', \'b\')) ++ si(cmpC(\'c\', \'b\')));',
    'print(showChar(\'x\') ++ showChar(\'é\') ++ showChar(\'\\u{1f600}\'));',
    'print(quoteChar(\'a\') ++ quoteChar(\'\\n\') ++ quoteChar(\'\\t\') ++ quoteChar(\'\\r\') ++ quoteChar(\'\\\\\') ++ quoteChar(\'\\\'\') ++ quoteChar(\'"\'));',
    'print(quoteChar(\'\\u{0}\') ++ quoteChar(\'\\u{1}\') ++ quoteChar(\'\\u{7f}\') ++ quoteChar(\'\\u{1f}\') ++ quoteChar(\'é\'));',
    "print(sb('a' < 'b') ++ sb('a' == 'a') ++ sb('b' >= 'c'));",
]

SWEEP_STR = [
    'print(si(strLen("")) ++ " " ++ si(strLen("abc")) ++ " " ++ si(strLen("héllo")) ++ " " ++ si(strLen("\\u{1f600}")));',
    'print(sc(charAt("héllo", 1)) ++ sc(charAt("héllo", 4)) ++ sc(charAt("a", 0)));',
    'print(substr("hello", 0, 5) ++ "|" ++ substr("hello", 1, 3) ++ "|" ++ substr("hello", 2, 2) ++ "|" ++ substr("", 0, 0));',
    'print(strCat("ab", "cd") ++ " " ++ strCat("", "x") ++ " " ++ ("a" ++ "b" ++ "c"));',
    'print(strRepeat("ab", 3) ++ "|" ++ strRepeat("ab", 0) ++ "|" ++ strRepeat("", 5));',
    'print(si(strIndexOf("abcabc", "bc")) ++ " " ++ si(strIndexOf("abc", "z")) ++ " " ++ si(strIndexOf("abc", "")) ++ " " ++ si(strIndexOf("", "a")));',
    'print(si(strLastIndexOf("abcabc", "bc")) ++ " " ++ si(strLastIndexOf("abc", "z")) ++ " " ++ si(strLastIndexOf("abc", "")));',
    'print(sb(strContains("abc", "bc")) ++ sb(strContains("abc", "cb")) ++ sb(strContains("abc", "")));',
    'print(sb(startsWith("abc", "ab")) ++ sb(startsWith("abc", "")) ++ sb(startsWith("a", "ab")) ++ sb(endsWith("abc", "bc")) ++ sb(endsWith("abc", "")) ++ sb(endsWith("a", "ab")));',
    'print(ss(strSplit("a,b,c", ",")) ++ ss(strSplit("a,,b", ",")) ++ ss(strSplit("", ",")) ++ ss(strSplit(",a,", ",")));',
    'print(ss(strSplit("aaa", "aa")) ++ ss(strSplit("abc", "abc")) ++ ss(strSplit("abc", "x")));',
    'print(strJoin(["a", "b", "c"], "-") ++ "|" ++ strJoin([], "-") ++ "|" ++ strJoin(["x"], "-") ++ "|" ++ strJoin(["a", "b"], ""));',
    'print(strReplace("hello", "l", "L") ++ " " ++ strReplace("aaa", "aa", "b") ++ " " ++ strReplace("abc", "z", "y") ++ " " ++ strReplace("aba", "a", ""));',
    'print("[" ++ trim("  x  ") ++ "][" ++ trim("\\t\\n x \\r\\n") ++ "][" ++ trim("   ") ++ "][" ++ trim("x") ++ "]");',
    'print("[" ++ trimLeft("  x  ") ++ "][" ++ trimRight("  x  ") ++ "][" ++ trimLeft("") ++ "]");',
    'print(upper("aZ9é") ++ " " ++ lower("AZ9É") ++ " " ++ upper("") ++ " " ++ lower("héllo"));',
    'print(si(strCmp("a", "b")) ++ si(strCmp("a", "a")) ++ si(strCmp("b", "a")) ++ si(strCmp("", "a")) ++ si(strCmp("ab", "a")) ++ si(strCmp("Z", "a")));',
    'print(si(listLen(chars("héllo"))) ++ " " ++ strOfChars(chars("héllo")) ++ " " ++ strOfChars([]) ++ " " ++ strOfChars([\'a\', \'b\']));',
    'print(strReverse("abc") ++ " " ++ strReverse("") ++ " " ++ strReverse("héllo"));',
    'print(quoteStr("") ++ " " ++ quoteStr("abc") ++ " " ++ quoteStr("a\\"b") ++ " " ++ quoteStr("a\\\\b"));',
    'print(quoteStr("a\\nb\\tc\\rd") ++ " " ++ quoteStr("\\u{0}\\u{1f}\\u{7f}") ++ " " ++ quoteStr("é\'"));',
    'print(padLeft("7", 3, \'0\') ++ " " ++ padLeft("abcd", 2, \'0\') ++ " " ++ padLeft("", 3, \'x\') ++ " " ++ padLeft("a", 0, \'x\'));',
    'print(padRight("7", 3, \'.\') ++ " " ++ padRight("abcd", 2, \'.\') ++ " " ++ padRight("", 2, \'é\'));',
    'print(sb("abc" < "abd") ++ sb("ab" < "abc") ++ sb("" < "a") ++ sb("abc" == "abc") ++ sb("Z" < "a"));',
    'print(si(strLen("a" ++ strRepeat("b", 100))) ++ " " ++ substr(strRepeat("xy", 4), 3, 6));',
]

SWEEP_LIST = [
    'let z: [Int] = listNew(); print(sl(z) ++ " " ++ si(listLen(z)));',
    'var a = [1, 2, 3]; push(a, 4); print(sl(a) ++ " " ++ si(listLen(a)));',
    'var b = [1, 2]; print(si(pop(b)) ++ " " ++ sl(b));',
    'var c = [1, 2]; insert(c, 0, 0); insert(c, 3, 9); print(sl(c));',
    'var d = [1, 2, 3]; print(si(removeAt(d, 1)) ++ " " ++ sl(d));',
    'var e = [1, 2]; clear(e); print(sl(e) ++ " " ++ si(listLen(e)));',
    'print(sl(listRepeat(7, 3)) ++ " " ++ sl(listRepeat(7, 0)));',
    'print(sl(listConcat([1], [2, 3])) ++ " " ++ sl(listConcat([], [])) ++ " " ++ sl([1] ++ [2]));',
    'print(sl(slice([1, 2, 3, 4], 1, 3)) ++ " " ++ sl(slice([1], 0, 0)) ++ " " ++ sl(slice([1, 2], 0, 2)));',
    'let f = [1, 2]; let g = listCopy(f); push(g, 3); print(sl(f) ++ " " ++ sl(g));',
    'print(sl(reverseList([1, 2, 3])) ++ " " ++ sl(reverseList([])) ++ " " ++ sl(reverseList([1])));',
    'print(si(listFirst([9, 8])) ++ " " ++ si(listLast([9, 8])) ++ " " ++ si(listFirst([5])));',
    'print(sl(listMap([1, 2, 3], |v| v * v)) ++ " " ++ ss(listMap([1, 2], |v| showInt(v))));',
    'print(sl(listFilter([1, 2, 3, 4], |v| v % 2 == 0)) ++ " " ++ sl(listFilter([1], |v| false)));',
    'print(si(listFold([1, 2, 3], 0, |a, x| a + x)) ++ " " ++ si(listFold(slice([1], 0, 0), 5, |a, x| a + x)) ++ " " ++ strJoin(listFold([1, 2], ["s"], |a, x| a ++ [showInt(x)]), "-"));',
    'print(sb(listAny([1, 2], |v| v > 1)) ++ sb(listAny(slice([1], 0, 0), |v| v > 0)) ++ sb(listAll([1, 2], |v| v > 0)) ++ sb(listAll(slice([1], 0, 0), |v| false)));',
    'print(so(listFind([1, 2, 3], |v| v > 1)) ++ " " ++ so(listFind([1], |v| v > 9)) ++ " " ++ si(listFindIndex([1, 2], |v| v == 2)) ++ " " ++ si(listFindIndex([1], |v| false)));',
    'print(si(listIndexOf([1, 2, 1], 1)) ++ " " ++ si(listIndexOf([1], 9)) ++ " " ++ sb(listContains(["a", "b"], "b")) ++ sb(listContains([1], 2)));',
    'print(si(listLen(listZip([1, 2, 3], ["a"]))) ++ " " ++ strJoin(listMap(listZip([1, 2], ["a", "b"]), |p| showInt(fst(p)) ++ snd(p)), ","));',
    'print(sl(listFlatten([[1], [2, 3], []])) ++ " " ++ sl(listFlatten([])));',
    'print(sl(sortBy([3, 1, 2], |a, b| cmpI(a, b))) ++ " " ++ sl(sortBy(slice([1], 0, 0), |a, b| 0)) ++ " " ++ sl(sortBy([1], |a, b| 0)));',
    'print(sl(sortBy([5, 4, 3, 2, 1], |a, b| cmpI(b, a))) ++ " " ++ ss(sortBy(["b", "a", "c"], |a, b| strCmp(a, b))));',
    'print(sl(sortBy([1, 2, 3, 4, 5, 6, 7], |a, b| cmpI(a % 2, b % 2))));',
    'let h = [1, 2]; let i2 = h; push(i2, 3); print(sl(h) ++ " " ++ sb(h == i2));',
    'print(sb([1, 2] == [1, 2]) ++ sb([1] == [1, 2]) ++ sb([[1]] == [[1]]) ++ sb(reverseList([1, 2]) == [2, 1]));',
]

SWEEP_MAP = [
    'var m: #[Str: Int] = mapNew(); print(si(mapLen(m)) ++ " " ++ sb(mapHas(m, "a")));',
    'var m = #["a": 1, "b": 2]; print(si(mapLen(m)) ++ " " ++ ss(keysOf(m)) ++ " " ++ sl(valuesOf(m)));',
    'var m = #["a": 1]; m["b"] = 2; m["a"] = 3; print(ss(keysOf(m)) ++ " " ++ sl(valuesOf(m)));',
    'var m = #["a": 1, "b": 2]; print(sb(mapDel(m, "a")) ++ sb(mapDel(m, "z")) ++ " " ++ ss(keysOf(m)));',
    'var m = #["a": 1, "b": 2]; mapDel(m, "a"); m["a"] = 9; print(ss(keysOf(m)) ++ " " ++ sl(valuesOf(m)));',
    'var m = #["a": 1]; print(so(mapGet(m, "a")) ++ " " ++ so(mapGet(m, "z")) ++ " " ++ si(mapGetOr(m, "a", -1)) ++ " " ++ si(mapGetOr(m, "z", -1)));',
    'var m: #[Int: Str] = mapNew(); mapSet(m, 2, "two"); mapSet(m, 1, "one"); print(sp(listMap(pairsOf(m), |p| (snd(p), fst(p)))));',
    'var m = #["a": 1]; mapClear(m); print(si(mapLen(m)) ++ " " ++ ss(keysOf(m)));',
    'var m = #["a": 1]; let n = mapCopy(m); n["b"] = 2; print(si(mapLen(m)) ++ si(mapLen(n)));',
    'var m = #["a": 1]; let n = m; n["b"] = 2; print(si(mapLen(m)) ++ sb(m == n));',
    'print(sb(#[1: "a", 2: "b"] == #[2: "b", 1: "a"]) ++ sb(#[1: "a"] == #[1: "b"]) ++ sb(#[1: "a"] == #[1: "a", 2: "b"]));',
    'var m = #[1: 1, 2: 4]; print(si(m[1]) ++ si(m[2]) ++ sb(mapHas(m, 3)));',
    'var m: #[Char: Int] = mapNew(); m[\'z\'] = 1; m[\'a\'] = 2; print(strOfChars(keysOf(m)) ++ " " ++ sl(valuesOf(m)));',
    'var m: #[Bool: Int] = mapNew(); m[true] = 1; m[false] = 0; print(si(mapLen(m)) ++ si(m[true]) ++ si(m[false]));',
    'var m: #[Str: [Int]] = mapNew(); m["a"] = [1]; push(m["a"], 2); print(sl(m["a"]) ++ " " ++ si(listLen(mapGetOr(m, "b", []))));',
    'var m: #[Int: Int] = mapNew(); for i in 0 .. 5 { m[i * 2] = i; } print(sl(keysOf(m)) ++ " " ++ sl(valuesOf(m)));',
    'var m: #[Str: Int] = mapNew(); for w in strSplit("b a b c a b", " ") { m[w] = mapGetOr(m, w, 0) + 1; } print(ss(keysOf(m)) ++ " " ++ sl(valuesOf(m)));',
]

SWEEP_OPT = [
    'let n: Option<Int> = None; print(sb(isSome(Some(1))) ++ sb(isSome(n)) ++ sb(isNone(Some(1))) ++ sb(isNone(n)));',
    'let n: Option<Int> = None; print(si(unwrap(Some(5))) ++ " " ++ si(unwrapOr(Some(5), 0)) ++ " " ++ si(unwrapOr(n, -1)));',
    'let a: Result<Int, Str> = Ok(1); let b: Result<Int, Str> = Err("e"); print(sb(isOk(a)) ++ sb(isOk(b)) ++ sb(isErr(a)) ++ sb(isErr(b)));',
    'let r: Result<Int, Str> = Ok(3); print(si(unwrapOk(r)) ++ " " ++ sb(isErr(r)));',
    'let r: Result<Int, Str> = Err("bad"); print(unwrapErr(r) ++ " " ++ sb(isOk(r)));',
    'let t = (1, "a"); print(si(fst(t)) ++ snd(t));',
    'let t = (Some(1), [2, 3]); print(so(fst(t)) ++ " " ++ sl(snd(t)));',
    'print(fmt("{} + {} = {}", ["1", "2", "3"]));',
    'print(fmt("{{{}}}", ["x"]) ++ " " ++ fmt("100%", []) ++ " " ++ fmt("{{}}", []) ++ " " ++ fmt("", []));',
    'print(fmt("{}{}{}", ["a", "", "c"]) ++ " " ++ fmt("}}{{", []) ++ " " ++ fmt("a{}", ["b"]));',
    'print(sb(Some(1) == Some(1)) ++ sb(Some(1) == None) ++ sb(isNone(mapGet(#[1: 2], 9))));',
    'let inner: Option<Int> = None; let o = Some(inner); print(sb(isSome(o)) ++ sb(isNone(unwrap(o))));',
    'let a: Result<Int, Str> = Ok(1); let b: Result<Int, Str> = Err("a"); print(sb(a == a) ++ sb(b == b) ++ sb(a == b));',
]

SWEEPS = [
    ('intlib', 'sweep_int', SWEEP_INT),
    ('floatlib', 'sweep_float', SWEEP_FLOAT),
    ('strlib', 'sweep_char', SWEEP_CHAR),
    ('strlib', 'sweep_str', SWEEP_STR),
    ('listlib', 'sweep_list', SWEEP_LIST),
    ('maplib', 'sweep_map', SWEEP_MAP),
    ('optlib', 'sweep_opt', SWEEP_OPT),
]


def hand_9():
    """Hand-written: pinned-down corners of the spec, and cases that separate
    subtly wrong implementations (frame limit, struct literal evaluation
    order, unordered map equality, reachability before exhaustiveness).
    'always' cases stay public whatever the area quota says."""
    add('runtime', 'frames_limit_method', '''@module main
trait Down { fn down(self) -> Int; }
impl Down for Int {
    fn down(self) -> Int { if self == 0 { 0 } else { (self - 1).down() + 1 } }
}
fn main() {
    print(showInt(19998.down()));
    print(showInt(19999.down()));
}
''', 'always', expect='panic')
    add('runtime', 'frames_limit_closure', '''@module main
fn rec(n: Int) -> Int {
    let g = |k: Int| rec(k);
    if n == 0 { 0 } else { g(n - 1) + 1 }
}
fn wrap(n: Int) -> Int { rec(n) }
fn main() {
    print(showInt(rec(9999)));
    print(showInt(wrap(9999)));
}
''', False, expect='panic')
    add('runtime', 'struct_eval_written_order', '''@module main
struct P { a: Int, b: Int, c: Int }
fn t(s: Str, v: Int) -> Int { emit(s); v }
fn main() {
    let p = P.{ c: t("c", 3), a: t("a", 1), b: t("b", 2) };
    print("");
    print(fmt("{} {} {}", [showInt(p.a), showInt(p.b), showInt(p.c)]));
}
''', 'always', expect='ok')
    add('runtime', 'struct_eval_order_panic', '''@module main
struct Box<T> { val: T, tag: Str }
fn say(s: Str) -> Str { print(s); s }
fn main() {
    let none: [Int] = listNew();
    let zero = listLen(none);
    let b: Box<Int> = Box.{ tag: say("tag first"), val: 7 };
    print(showInt(b.val));
    let c: Box<Int> = Box.{ tag: say("written first"), val: 1 / zero };
    print(c.tag);
}
''', False, expect='panic')
    add('value', 'map_eq_unordered', '''@module main
fn main() {
    let a = #["x": 1, "y": 2, "z": 3];
    let b = #["z": 3, "x": 1, "y": 2];
    print(showBool(a == b));
    print(showBool(a != b));
    print(showBool([a] == [b]));
    b["x"] = 9;
    print(showBool(a == b));
    let c = #[1: [1, 2], 2: [3]];
    let d = #[2: [3], 1: [1, 2]];
    print(showBool(c == d));
}
''', 'always', expect='ok')
    add('exhaust', 'unreach_before_nonexh_bool', '''@module main
fn f(b: Bool) -> Int {
    match b {
        true -> 1,
        true -> 2,
    }
}
fn main() { print(showInt(f(true))); }
''', 'always', expect='error unreachable')
    add('exhaust', 'unreach_before_nonexh_enum', '''@module main
enum Tri { A, B, C(Int) }
fn f(t: Tri) -> Int {
    match t {
        C(0) -> 0,
        A -> 1,
        B -> 2,
        A -> 3,
    }
}
fn main() { print(showInt(f(A))); }
''', False, expect='error unreachable')
    shapes = '''@module za
pub trait Shape { fn name(self) -> Str; }
impl Shape for Int { fn name(self) -> Str { "za" } }
@module ab
pub trait Shape { fn name(self) -> Str; }
impl Shape for Bool { fn name(self) -> Str { "ab" } }
'''
    add('module', 'trait_path_import_order', '''@module main
use za;
use ab;
fn main() {
    print(Shape::name(true));
}
''' + shapes, 'always', expect='ok')
    add('module', 'trait_path_alias_order', '''@module main
use ab as zz;
use za as aa;
fn main() {
    print(Shape::name(1));
}
''' + shapes, False, expect='ok')
    add('module', 'trait_path_own_first', '''@module main
use ab;
trait Shape { fn name(self) -> Str; }
impl Shape for Bool { fn name(self) -> Str { "own" } }
fn main() {
    print(Shape::name(false));
}
''' + shapes, False, expect='ok')
    add('generic', 'tparam_hides_struct', '''@module main
struct T { a: Int }
fn same<T>(x: T) -> T { x }
fn main() {
    print(same("param wins"));
    print(showInt(same(T.{ a: 4 }).a));
}
''', 'always', expect='ok')
    add('generic', 'tparam_named_int', '''@module main
struct S<Int> { a: Int }
fn id<Int>(x: Int) -> Int { x }
fn main() {
    print(id("text"));
    let s = S.{ a: true };
    print(showBool(s.a));
}
''', False, expect='ok')
    add('lex', 'exponent_underscores', '''@module main
fn main() {
    print(showFloat(1_.5));
    print(showFloat(1e1_0));
    print(showFloat(2_5.0_5e-0_1));
}
''', 'always', expect='ok')
    add('lex', 'char_two_with_escape', "@module main\nfn main() {\n    let c = 'a\\q';\n}\n",
        False, expect='error unterminated')
    add('lex', 'string_escape_before_eol', '@module main\nfn main() {\n    let s = "ab\\q\n}\n',
        False, expect='error bad-escape')
    add('lex', 'backslash_at_module_end', '@module main\nfn main() {}\nfn f() { let s = "\\',
        False, expect='error bad-escape')
    add('type', 'map_key_checked_after_value', '''@module main
fn f(m: #[Float: Nope]) -> Int { 0 }
fn main() {}
''', False, expect='error unknown-type')
    add('parse', 'if_stmt_continues_as_call', '''@module main
fn f() {}
fn main() {
    let c = true;
    if c { f() } else { f() }
    (1, 2);
}
''', 'always', expect='error not-callable')
    add('parse', 'match_stmt_continues_as_minus', '''@module main
fn main() {
    let n = 3;
    match n { _ -> print("x") }
    -1;
}
''', False, expect='error type-mismatch')


def library_sweeps():
    """One program per chunk of library calls, each line a call transcript."""
    for area, base, entries in SWEEPS:
        chunks = [entries[i:i + 7] for i in range(0, len(entries), 7)]
        for i, chunk in enumerate(chunks, 1):
            body = ''.join('    %s\n' % line for line in chunk)
            src = ('@module main\n' + SWEEP_HELPERS
                   + 'fn main() {\n' + body + '}\n')
            add(area, '%s_%d' % (base, i), src, True if i == 1 else None)


# --- panics: one tiny program per raising site ----------------------------

PANICS = [
    ('div_zero', 'print("a"); print(showInt(7 / (1 - 1)));'),
    ('mod_zero', 'print(showInt(7 % (1 - 1)));'),
    ('divfloor_zero', 'print(showInt(divFloor(7, 0)));'),
    ('modfloor_zero', 'print(showInt(modFloor(7, 0)));'),
    ('shift_left_64', 'print(showInt(1 << 64));'),
    ('shift_right_neg', 'print(showInt(8 >> -1));'),
    ('index_list', 'let xs = [1, 2]; emit("x"); print(showInt(xs[2]));'),
    ('index_list_neg', 'let xs = [1]; print(showInt(xs[-1]));'),
    ('index_str', 'print(showChar("ab"[2]));'),
    ('index_assign', 'var xs = [1]; xs[1] = 2;'),
    ('index_insert', 'var xs = [1]; insert(xs, 2, 0);'),
    ('index_remove_at', 'var xs = [1]; print(showInt(removeAt(xs, 1)));'),
    ('index_substr', 'print(substr("abc", 1, 4));'),
    ('index_slice', 'print(showInt(listLen(slice([1, 2], 0, 3))));'),
    ('index_char_at', 'print(showChar(charAt("abc", 3)));'),
    ('missing_key', 'let m = #["a": 1]; print(showInt(m["b"]));'),
    ('unwrap_none', 'let o: Option<Int> = None; print(showInt(unwrap(o)));'),
    ('unwrap_err', 'let r: Result<Int, Str> = Err("e"); print(showInt(unwrapOk(r)));'),
    ('unwrap_ok', 'let r: Result<Int, Str> = Ok(1); print(unwrapErr(r));'),
    ('empty_pop', 'var xs: [Int] = listNew(); print(showInt(pop(xs)));'),
    ('empty_first', 'var xs: [Int] = listNew(); print(showInt(listFirst(xs)));'),
    ('invalid_char_high', 'print(showChar(chr(1114112)));'),
    ('invalid_char_surrogate', 'print(showChar(chr(0xd800)));'),
    ('float_range_nan', 'print(showInt(truncToInt(nanF())));'),
    ('float_range_inf', 'print(showInt(truncToInt(infF())));'),
    ('float_range_edge', 'print(showInt(truncToInt(-9.3e18)));'),
    ('negative_count_str', 'print(strRepeat("a", -1));'),
    ('negative_count_list', 'print(showInt(listLen(listRepeat(1, -2))));'),
    ('negative_count_pad_left', 'print(padLeft("a", -1, \'x\'));'),
    ('negative_exponent', 'print(showInt(powI(2, -1)));'),
    ('negative_exponent_powf', 'print(showFloat(powF(2.0, intMin())));'),
    ('empty_separator_split', 'print(showInt(listLen(strSplit("ab", ""))));'),
    ('empty_separator_replace', 'print(strReplace("ab", "", "x"));'),
    ('bad_format_count_more', 'print(fmt("{} {}", ["a"]));'),
    ('bad_format_count_fewer', 'print(fmt("{}", ["a", "b"]));'),
    ('bad_format_brace', 'print(fmt("a{b", []));'),
    ('bad_format_close', 'print(fmt("a}b", ["x"]));'),
    ('bad_format_order', 'print(fmt("{x} {}", []));'),
    ('radix_low', 'print(showIntRadix(5, 1));'),
    ('radix_high', 'print(showIntRadix(5, 37));'),
    ('radix_parse', 'print(showInt(unwrapOr(parseIntRadix("5", 0), 0)));'),
    ('digits_high', 'print(showFloatAt(1.0, 18));'),
    ('digits_from_loop', 'for d in [17, 5, -1] { print(showFloatAt(0.125, d)); }'),
    ('unwrap_ok_in_map', 'let rs: [Result<Int, Str>] = [Err("x"), Ok(2)]; for r in rs { print(unwrapErr(r)); }'),
    ('custom_message', 'emit("before:"); panic("it broke"); print("after");'),
    ('custom_empty', 'panic("");'),
    ('custom_newline', 'panic("two\\nlines");'),
    ('panic_in_callback', 'print(showInt(listLen(listMap([1, 2], |v| showInt(v / (v - 1))))));'),
    ('panic_in_sort', 'print(showInt(listLen(sortBy([1, 2, 3], |a, b| a / (b - b)))));'),
    ('panic_after_output', 'for i in 0 .. 3 { emit(showInt(i)); } print(""); print(showInt([1][9]));'),
]


def panic_cases():
    for i, (name, body) in enumerate(PANICS):
        src = '@module main\nfn main() {\n    %s\n}\n' % body
        add('runtime', 'panic_' + name, src, True if i % 4 == 0 else None)


# --- inference limits -----------------------------------------------------

INFER_LIMITS = [
    ('empty_list_synth', 'let xs = [];'),
    ('empty_map_synth', 'let m = #[];'),
    ('list_new_nested', 'print(showInt(listLen(listNew())));'),
    ('none_as_arg', 'print(showBool(isSome(None)));'),
    ('ok_synth', 'print(showBool(isOk(Ok(1))));'),
    ('nested_some_none', 'let o: Option<Option<Int>> = Some(None);'),
    ('fold_empty', 'print(showInt(listFold([], 0, |a: Int, x: Int| a)));'),
    ('sort_empty', 'print(showInt(listLen(sortBy([], |a: Int, b: Int| 0))));'),
    ('lambda_unannotated', 'let f = |x| x;'),
    ('lambda_some_annotated', 'let f = |a: Int, b| a;'),
    ('map_new_synth', 'print(showInt(mapLen(mapNew())));'),
    ('zip_empty', 'print(showInt(listLen(listZip([], [1]))));'),
]


def inference_limit_cases():
    for i, (name, body) in enumerate(INFER_LIMITS):
        src = '@module main\nfn main() {\n    %s\n}\n' % body
        add('generic', 'infer_' + name, src, True if i % 4 == 0 else None)


# @@PROGRAMS@@
# --- whole programs -------------------------------------------------------
#
# Hand-written multi-feature programs, each a few hundred lines at most.  Their
# output was checked by hand where it has an independent meaning (factorials,
# Fibonacci numbers, determinants, the sudoku solution, the n-queens counts).

PROGRAMS = {}

PROGRAMS['interp'] = r'''@module main
use lex;
use ast;
use eval;

fn main() {
    let progs = [
        "let x = 3; let y = x * (2 + 4); print y;",
        "let a = 10; while a > 0 { a = a - 3; } print a;",
        "let s = 0; let i = 1; while i <= 10 { s = s + i; i = i + 1; } print s;",
        "print 1 + 2 * 3 - 4 / 2;",
        "let b = 1; if b { print 42; } else { print 0; }",
        "print undefinedVar;",
        "print 1 / 0;",
        "let q = ;",
    ];
    for p in progs {
        emit(padRight(p, 46, '.'));
        emit(" => ");
        match eval::runProgram(p) {
            Ok(out) -> print(out),
            Err(e) -> print("error: " ++ e),
        }
    }
}
@module lex
pub enum Tok {
    Num(Int),
    Name(Str),
    Sym(Str),
    Kw(Str),
}

pub fn isKeyword(s: Str) -> Bool {
    listContains(["let", "print", "while", "if", "else"], s)
}

pub fn tokenize(src: Str) -> Result<[Tok], Str> {
    var out: [Tok] = listNew();
    var i = 0;
    let n = strLen(src);
    while i < n {
        let c = charAt(src, i);
        if isSpace(c) {
            i = i + 1;
        } else if isDigit(c) {
            var v = 0;
            while i < n && isDigit(charAt(src, i)) {
                v = v * 10 + (ord(charAt(src, i)) - 48);
                i = i + 1;
            }
            push(out, Num(v));
        } else if isAlpha(c) || c == '_' {
            var j = i;
            while j < n && (isAlnum(charAt(src, j)) || charAt(src, j) == '_') {
                j = j + 1;
            }
            let word = substr(src, i, j);
            if isKeyword(word) { push(out, Kw(word)); } else { push(out, Name(word)); }
            i = j;
        } else {
            let two = if i + 1 < n { substr(src, i, i + 2) } else { "" };
            if listContains(["<=", ">=", "==", "!="], two) {
                push(out, Sym(two));
                i = i + 2;
            } else if listContains(["+", "-", "*", "/", "(", ")", "{", "}", ";", "=", "<", ">"], showChar(c)) {
                push(out, Sym(showChar(c)));
                i = i + 1;
            } else {
                return Err("bad character " ++ quoteChar(c));
            }
        }
    }
    Ok(out)
}
@module ast
pub enum Expr {
    Lit(Int),
    Var(Str),
    Bin(Str, Expr, Expr),
}

pub enum Stmt {
    Let(Str, Expr),
    Assign(Str, Expr),
    Print(Expr),
    While(Expr, [Stmt]),
    If(Expr, [Stmt], [Stmt]),
}
@module eval
use lex;
use ast;

struct Parser { toks: [lex::Tok], pos: [Int] }

fn peek(p: Parser) -> Option<lex::Tok> {
    let i = p.pos[0];
    if i < listLen(p.toks) { Some(p.toks[i]) } else { None }
}

fn bump(p: Parser) { p.pos[0] = p.pos[0] + 1; }

fn eatSym(p: Parser, s: Str) -> Bool {
    match peek(p) {
        Some(lex::Sym(t)) -> if t == s { bump(p); true } else { false },
        _ -> false,
    }
}

fn parseStmts(p: Parser, stop: Bool) -> Result<[ast::Stmt], Str> {
    var out: [ast::Stmt] = listNew();
    while true {
        match peek(p) {
            None -> { return Ok(out); },
            Some(lex::Sym("}")) -> { if stop { return Ok(out); } },
            _ -> {},
        }
        match parseStmt(p) {
            Ok(s) -> push(out, s),
            Err(e) -> { return Err(e); },
        }
    }
    Ok(out)
}

fn parseBlock(p: Parser) -> Result<[ast::Stmt], Str> {
    if !eatSym(p, "{") { return Err("expected {"); }
    let body = parseStmts(p, true);
    match body {
        Err(e) -> { return Err(e); },
        Ok(_) -> {},
    }
    if !eatSym(p, "}") { return Err("expected }"); }
    body
}

fn parseStmt(p: Parser) -> Result<ast::Stmt, Str> {
    match peek(p) {
        Some(lex::Kw("let")) -> {
            bump(p);
            match peek(p) {
                Some(lex::Name(n)) -> {
                    bump(p);
                    if !eatSym(p, "=") { return Err("expected ="); }
                    match parseExpr(p, 0) {
                        Ok(e) -> {
                            if !eatSym(p, ";") { return Err("expected ;"); }
                            Ok(ast::Let(n, e))
                        },
                        Err(e) -> Err(e),
                    }
                },
                _ -> Err("expected a name after let"),
            }
        },
        Some(lex::Kw("print")) -> {
            bump(p);
            match parseExpr(p, 0) {
                Ok(e) -> {
                    if !eatSym(p, ";") { return Err("expected ;"); }
                    Ok(ast::Print(e))
                },
                Err(e) -> Err(e),
            }
        },
        Some(lex::Kw("while")) -> {
            bump(p);
            match parseExpr(p, 0) {
                Ok(cond) -> match parseBlock(p) {
                    Ok(body) -> Ok(ast::While(cond, body)),
                    Err(e) -> Err(e),
                },
                Err(e) -> Err(e),
            }
        },
        Some(lex::Kw("if")) -> {
            bump(p);
            match parseExpr(p, 0) {
                Ok(cond) -> match parseBlock(p) {
                    Ok(then) -> {
                        var els: [ast::Stmt] = listNew();
                        match peek(p) {
                            Some(lex::Kw("else")) -> {
                                bump(p);
                                match parseBlock(p) {
                                    Ok(b) -> { els = b; },
                                    Err(e) -> { return Err(e); },
                                }
                            },
                            _ -> {},
                        }
                        Ok(ast::If(cond, then, els))
                    },
                    Err(e) -> Err(e),
                },
                Err(e) -> Err(e),
            }
        },
        Some(lex::Name(n)) -> {
            bump(p);
            if !eatSym(p, "=") { return Err("expected = after " ++ n); }
            match parseExpr(p, 0) {
                Ok(e) -> {
                    if !eatSym(p, ";") { return Err("expected ;"); }
                    Ok(ast::Assign(n, e))
                },
                Err(e) -> Err(e),
            }
        },
        _ -> Err("expected a statement"),
    }
}

fn prec(s: Str) -> Int {
    if s == "<" || s == ">" || s == "<=" || s == ">=" || s == "==" || s == "!=" { 1 }
    else if s == "+" || s == "-" { 2 }
    else if s == "*" || s == "/" { 3 }
    else { -1 }
}

fn parseExpr(p: Parser, minPrec: Int) -> Result<ast::Expr, Str> {
    var left = match parsePrimary(p) {
        Ok(e) -> e,
        Err(e) -> { return Err(e); },
    };
    while true {
        let op = match peek(p) {
            Some(lex::Sym(s)) -> s,
            _ -> "",
        };
        let pr = prec(op);
        if pr < 0 || pr < minPrec { return Ok(left); }
        bump(p);
        match parseExpr(p, pr + 1) {
            Ok(right) -> { left = ast::Bin(op, left, right); },
            Err(e) -> { return Err(e); },
        }
    }
    Ok(left)
}

fn parsePrimary(p: Parser) -> Result<ast::Expr, Str> {
    match peek(p) {
        Some(lex::Num(v)) -> { bump(p); Ok(ast::Lit(v)) },
        Some(lex::Name(n)) -> { bump(p); Ok(ast::Var(n)) },
        Some(lex::Sym("(")) -> {
            bump(p);
            match parseExpr(p, 0) {
                Ok(e) -> {
                    if !eatSym(p, ")") { return Err("expected )"); }
                    Ok(e)
                },
                Err(e) -> Err(e),
            }
        },
        _ -> Err("expected an expression"),
    }
}

struct Env { vars: #[Str: Int], out: [Str] }

fn evalExpr(e: ast::Expr, env: Env) -> Result<Int, Str> {
    match e {
        ast::Lit(v) -> Ok(v),
        ast::Var(n) -> match mapGet(env.vars, n) {
            Some(v) -> Ok(v),
            None -> Err("unbound " ++ n),
        },
        ast::Bin(op, l, r) -> match evalExpr(l, env) {
            Err(m) -> Err(m),
            Ok(a) -> match evalExpr(r, env) {
                Err(m) -> Err(m),
                Ok(b) -> applyOp(op, a, b),
            },
        },
    }
}

fn applyOp(op: Str, a: Int, b: Int) -> Result<Int, Str> {
    if op == "+" { Ok(a + b) }
    else if op == "-" { Ok(a - b) }
    else if op == "*" { Ok(a * b) }
    else if op == "/" { if b == 0 { Err("division by zero") } else { Ok(a / b) } }
    else if op == "<" { Ok(boolToInt(a < b)) }
    else if op == ">" { Ok(boolToInt(a > b)) }
    else if op == "<=" { Ok(boolToInt(a <= b)) }
    else if op == ">=" { Ok(boolToInt(a >= b)) }
    else if op == "==" { Ok(boolToInt(a == b)) }
    else if op == "!=" { Ok(boolToInt(a != b)) }
    else { Err("bad operator " ++ op) }
}

fn boolToInt(b: Bool) -> Int { if b { 1 } else { 0 } }

fn execAll(stmts: [ast::Stmt], env: Env) -> Option<Str> {
    for s in stmts {
        match exec(s, env) {
            Some(e) -> { return Some(e); },
            None -> {},
        }
    }
    None
}

fn exec(s: ast::Stmt, env: Env) -> Option<Str> {
    match s {
        ast::Let(n, e) -> match evalExpr(e, env) {
            Ok(v) -> { env.vars[n] = v; None },
            Err(m) -> Some(m),
        },
        ast::Assign(n, e) -> if !mapHas(env.vars, n) { Some("unbound " ++ n) } else {
            match evalExpr(e, env) {
                Ok(v) -> { env.vars[n] = v; None },
                Err(m) -> Some(m),
            }
        },
        ast::Print(e) -> match evalExpr(e, env) {
            Ok(v) -> { push(env.out, showInt(v)); None },
            Err(m) -> Some(m),
        },
        ast::While(cond, body) -> {
            var guard = 0;
            while true {
                match evalExpr(cond, env) {
                    Err(m) -> { return Some(m); },
                    Ok(v) -> if v == 0 { return None; },
                }
                guard = guard + 1;
                if guard > 1000 { return Some("loop limit"); }
                match execAll(body, env) {
                    Some(m) -> { return Some(m); },
                    None -> {},
                }
            }
            None
        },
        ast::If(cond, then, els) -> match evalExpr(cond, env) {
            Err(m) -> Some(m),
            Ok(v) -> if v != 0 { execAll(then, env) } else { execAll(els, env) },
        },
    }
}

pub fn runProgram(src: Str) -> Result<Str, Str> {
    match lex::tokenize(src) {
        Err(e) -> Err(e),
        Ok(toks) -> {
            let p = Parser.{ toks: toks, pos: [0] };
            match parseStmts(p, false) {
                Err(e) -> Err(e),
                Ok(stmts) -> {
                    let env = Env.{ vars: mapNew(), out: listNew() };
                    match execAll(stmts, env) {
                        Some(e) -> Err(e),
                        None -> Ok(strJoin(env.out, " ")),
                    }
                },
            }
        },
    }
}
'''

PROGRAMS['dijkstra'] = r'''@module main
use heap;
use graph as g;

fn main() {
    let gr = g::grid(12, 9, 7);
    let dist = g::shortest(gr, 0);
    for row in 0 .. 9 {
        var parts: [Str] = listNew();
        for col in 0 .. 12 {
            push(parts, padLeft(showInt(dist[row * 12 + col]), 4, ' '));
        }
        print(strJoin(parts, ""));
    }
    let far = listFold(dist, 0, |a, d| maxI(a, d));
    print(fmt("farthest={} edges={}", [showInt(far), showInt(g::edgeCount(gr))]));
    var h: heap::Heap<Str> = heap::new(|a: Str, b: Str| strLen(a) < strLen(b) || (strLen(a) == strLen(b) && a < b));
    for w in strSplit("pear fig apple kiwi banana date plum", " ") {
        heap::add(h, w);
    }
    var order: [Str] = listNew();
    while !heap::isEmpty(h) {
        push(order, heap::take(h));
    }
    print(strJoin(order, " "));
}
@module heap
pub struct Heap<T> { items: [T], less: fn(T, T) -> Bool }

pub fn new<T>(less: fn(T, T) -> Bool) -> Heap<T> {
    Heap.{ items: listNew(), less: less }
}

pub fn isEmpty<T>(h: Heap<T>) -> Bool { listLen(h.items) == 0 }

pub fn add<T>(h: Heap<T>, x: T) {
    let xs = h.items;
    push(xs, x);
    var i = listLen(xs) - 1;
    while i > 0 {
        let p = (i - 1) / 2;
        let lt = h.less;
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
    if listLen(xs) > 0 {
        xs[0] = last;
        var i = 0;
        let n = listLen(xs);
        let lt = h.less;
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
@module graph
use heap;

pub struct Graph { n: Int, adj: [[(Int, Int)]] }

pub fn grid(w: Int, h: Int, seed: Int) -> Graph {
    var adj: [[(Int, Int)]] = listNew();
    for i in 0 .. w * h { push(adj, listNew()); }
    var s = seed;
    for y in 0 .. h {
        for x in 0 .. w {
            let v = y * w + x;
            if x + 1 < w {
                s = (s * 1103515245 + 12345) % 2147483648;
                let c = 1 + s % 9;
                push(adj[v], (v + 1, c));
                push(adj[v + 1], (v, c));
            }
            if y + 1 < h {
                s = (s * 1103515245 + 12345) % 2147483648;
                let c = 1 + s % 9;
                push(adj[v], (v + w, c));
                push(adj[v + w], (v, c));
            }
        }
    }
    Graph.{ n: w * h, adj: adj }
}

pub fn edgeCount(g: Graph) -> Int {
    listFold(g.adj, 0, |a, es| a + listLen(es)) / 2
}

pub fn shortest(g: Graph, src: Int) -> [Int] {
    var dist = listRepeat(-1, g.n);
    var h = heap::new(|a: (Int, Int), b: (Int, Int)| fst(a) < fst(b) || (fst(a) == fst(b) && snd(a) < snd(b)));
    heap::add(h, (0, src));
    while !heap::isEmpty(h) {
        let (d, v) = heap::take(h);
        if dist[v] >= 0 { continue; }
        dist[v] = d;
        for (u, c) in g.adj[v] {
            if dist[u] < 0 { heap::add(h, (d + c, u)); }
        }
    }
    dist
}
'''

PROGRAMS['rational'] = r'''@module main
use num;

fn identity<T: num::Num>(n: Int, zero: T, one: T) -> [[T]] {
    var m: [[T]] = listNew();
    for i in 0 .. n {
        var row: [T] = listNew();
        for j in 0 .. n {
            push(row, if i == j { one } else { zero });
        }
        push(m, row);
    }
    m
}

fn matMul<T: num::Num>(a: [[T]], b: [[T]], zero: T) -> [[T]] {
    let n = listLen(a);
    let k = listLen(b);
    let p = listLen(b[0]);
    var out: [[T]] = listNew();
    for i in 0 .. n {
        var row: [T] = listNew();
        for j in 0 .. p {
            var acc = zero;
            for t in 0 .. k {
                acc = acc.add(a[i][t].mul(b[t][j]));
            }
            push(row, acc);
        }
        push(out, row);
    }
    out
}

fn showMat<T: num::Num>(m: [[T]]) -> Str {
    strJoin(listMap(m, |row| "[" ++ strJoin(listMap(row, |x| x.show()), " ") ++ "]"), "\n")
}

fn matPow<T: num::Num>(m: [[T]], e: Int, zero: T, one: T) -> [[T]] {
    var result = identity(listLen(m), zero, one);
    var base = m;
    var k = e;
    while k > 0 {
        if k % 2 == 1 { result = matMul(result, base, zero); }
        base = matMul(base, base, zero);
        k = k / 2;
    }
    result
}

fn det(m: [[num::Rat]]) -> num::Rat {
    let n = listLen(m);
    var a: [[num::Rat]] = listMap(m, |row| listCopy(row));
    var d = num::rat(1, 1);
    for c in 0 .. n {
        var piv = -1;
        for r in c .. n {
            if piv < 0 && !num::isZero(a[r][c]) { piv = r; }
        }
        if piv < 0 { return num::rat(0, 1); }
        if piv != c {
            let t = a[piv];
            a[piv] = a[c];
            a[c] = t;
            d = d.neg();
        }
        d = d.mul(a[c][c]);
        for r in c + 1 .. n {
            let f = num::div(a[r][c], a[c][c]);
            for j in c .. n {
                a[r][j] = a[r][j].add(f.mul(a[c][j]).neg());
            }
        }
    }
    d
}

fn main() {
    let fibm = [[1, 1], [1, 0]];
    print(showMat(matPow(fibm, 10, 0, 1)));
    print(showInt(matPow(fibm, 90, 0, 1)[0][1]));
    let h = listMap([0, 1, 2, 3], |i| listMap([0, 1, 2, 3], |j| num::rat(1, i + j + 1)));
    print(showMat(h));
    print("det(hilbert4) = " ++ det(h).show());
    let m = [[num::rat(2, 1), num::rat(-1, 2), num::rat(0, 1)],
             [num::rat(1, 3), num::rat(4, 1), num::rat(-2, 5)],
             [num::rat(0, 1), num::rat(7, 6), num::rat(1, 1)]];
    print("det(m) = " ++ det(m).show());
    print(showMat(matMul(m, identity(3, num::rat(0, 1), num::rat(1, 1)), num::rat(0, 1))));
    print(showMat(matPow(m, 3, num::rat(0, 1), num::rat(1, 1))));
    let sing = [[num::rat(1, 2), num::rat(1, 1)], [num::rat(1, 4), num::rat(1, 2)]];
    print("det(sing) = " ++ det(sing).show());
    var harmonic = num::rat(0, 1);
    for i in 1 .. 21 {
        harmonic = harmonic.add(num::rat(1, i));
    }
    print("H20 = " ++ harmonic.show());
    print(showBool(num::rat(2, 4) == num::rat(-3, -6)) ++ " " ++ showBool(num::rat(1, 3) == num::rat(1, 4)));
}
@module num
pub trait Num {
    fn add(self, o: Self) -> Self;
    fn mul(self, o: Self) -> Self;
    fn neg(self) -> Self;
    fn show(self) -> Str;
}

pub struct Rat { n: Int, d: Int }

pub fn rat(n: Int, d: Int) -> Rat {
    let g = gcdI(n, d);
    let s = if d < 0 { -1 } else { 1 };
    if g == 0 { Rat.{ n: 0, d: 1 } } else { Rat.{ n: s * n / g, d: s * d / g } }
}

pub fn isZero(r: Rat) -> Bool { r.n == 0 }

pub fn div(a: Rat, b: Rat) -> Rat { rat(a.n * b.d, a.d * b.n) }

impl Num for Int {
    fn add(self, o: Int) -> Int { self + o }
    fn mul(self, o: Int) -> Int { self * o }
    fn neg(self) -> Int { -self }
    fn show(self) -> Str { showInt(self) }
}

impl Num for Rat {
    fn add(self, o: Rat) -> Rat { rat(self.n * o.d + o.n * self.d, self.d * o.d) }
    fn mul(self, o: Rat) -> Rat { rat(self.n * o.n, self.d * o.d) }
    fn neg(self) -> Rat { Rat.{ n: -self.n, d: self.d } }
    fn show(self) -> Str {
        if self.d == 1 { showInt(self.n) } else { showInt(self.n) ++ "/" ++ showInt(self.d) }
    }
}
'''

PROGRAMS['jsonish'] = r'''@module main
use doc;

fn main() {
    let inputs = [
        "{\"name\": \"vellum\", \"tags\": [\"vm\", \"lang\"], \"size\": 42}",
        "[1, -2, [3, [4, []]], {}, true, false, null]",
        "{\"a\": {\"b\": {\"c\": [\"deep\\n\\\"q\\\"\"]}}}",
        "  [  ]  ",
        "{\"k\": }",
        "[1, 2,]",
        "\"unterminated",
        "{\"x\": 1} trailing",
        "[007, -0]",
        "{\"dup\": 1, \"dup\": 2}",
    ];
    for src in inputs {
        print("> " ++ src);
        match doc::parse(src) {
            Ok(v) -> {
                print(doc::pretty(v, 0));
                print("compact: " ++ doc::compact(v) ++ " nodes=" ++ showInt(doc::count(v)));
            },
            Err((pos, msg)) -> print(fmt("error at {}: {}", [showInt(pos), msg])),
        }
    }
}
@module doc
pub enum Val {
    VNull,
    VBool(Bool),
    VNum(Int),
    VStr(Str),
    VArr([Val]),
    VObj([(Str, Val)]),
}

struct P { src: [Char], pos: [Int] }

fn peek(p: P) -> Option<Char> {
    let i = p.pos[0];
    if i < listLen(p.src) { Some(p.src[i]) } else { None }
}

fn bump(p: P) { p.pos[0] = p.pos[0] + 1; }

fn skipWs(p: P) {
    while true {
        match peek(p) {
            Some(c) when isSpace(c) -> bump(p),
            _ -> { break; }
        }
    }
}

fn fail<T>(p: P, msg: Str) -> Result<T, (Int, Str)> { Err((p.pos[0], msg)) }

fn expectWord(p: P, w: Str, v: Val) -> Result<Val, (Int, Str)> {
    for c in w {
        if peek(p) != Some(c) { return fail(p, "bad literal"); }
        bump(p);
    }
    Ok(v)
}

fn parseStr(p: P) -> Result<Str, (Int, Str)> {
    bump(p);
    var out: [Char] = listNew();
    while true {
        match peek(p) {
            None -> { return fail(p, "unterminated string"); }
            Some('"') -> { bump(p); return Ok(strOfChars(out)); }
            Some('\\') -> {
                bump(p);
                match peek(p) {
                    Some('n') -> push(out, '\n'),
                    Some('"') -> push(out, '"'),
                    Some('\\') -> push(out, '\\'),
                    _ -> { return fail(p, "bad escape"); }
                }
                bump(p);
            }
            Some(c) -> { push(out, c); bump(p); }
        }
    }
    fail(p, "unreachable")
}

fn parseNum(p: P) -> Result<Val, (Int, Str)> {
    let start = p.pos[0];
    var neg = false;
    if peek(p) == Some('-') { neg = true; bump(p); }
    var v = 0;
    var digits = 0;
    while true {
        match peek(p) {
            Some(c) when isDigit(c) -> {
                if digits == 1 && v == 0 { return Err((start, "leading zero")); }
                v = v * 10 + ord(c) - 48;
                digits = digits + 1;
                bump(p);
            }
            _ -> { break; }
        }
    }
    if digits == 0 { return fail(p, "expected digit"); }
    Ok(VNum(if neg { -v } else { v }))
}

fn parseVal(p: P) -> Result<Val, (Int, Str)> {
    skipWs(p);
    match peek(p) {
        None -> fail(p, "unexpected end"),
        Some('n') -> expectWord(p, "null", VNull),
        Some('t') -> expectWord(p, "true", VBool(true)),
        Some('f') -> expectWord(p, "false", VBool(false)),
        Some('"') -> match parseStr(p) {
            Ok(s) -> Ok(VStr(s)),
            Err(e) -> Err(e),
        },
        Some('[') -> {
            bump(p);
            var items: [Val] = listNew();
            skipWs(p);
            if peek(p) == Some(']') { bump(p); return Ok(VArr(items)); }
            while true {
                match parseVal(p) {
                    Ok(v) -> push(items, v),
                    Err(e) -> { return Err(e); }
                }
                skipWs(p);
                match peek(p) {
                    Some(',') -> bump(p),
                    Some(']') -> { bump(p); return Ok(VArr(items)); }
                    _ -> { return fail(p, "expected , or ]"); }
                }
            }
            fail(p, "unreachable")
        }
        Some('{') -> {
            bump(p);
            var fields: [(Str, Val)] = listNew();
            var seen: #[Str: Bool] = mapNew();
            skipWs(p);
            if peek(p) == Some('}') { bump(p); return Ok(VObj(fields)); }
            while true {
                skipWs(p);
                if peek(p) != Some('"') { return fail(p, "expected key"); }
                let at = p.pos[0];
                let key = match parseStr(p) { Ok(s) -> s, Err(e) -> { return Err(e); } };
                if mapHas(seen, key) { return Err((at, "duplicate key " ++ quoteStr(key))); }
                seen[key] = true;
                skipWs(p);
                if peek(p) != Some(':') { return fail(p, "expected :"); }
                bump(p);
                let v = match parseVal(p) { Ok(v) -> v, Err(e) -> { return Err(e); } };
                push(fields, (key, v));
                skipWs(p);
                match peek(p) {
                    Some(',') -> bump(p),
                    Some('}') -> { bump(p); return Ok(VObj(fields)); }
                    _ -> { return fail(p, "expected , or }"); }
                }
            }
            fail(p, "unreachable")
        }
        Some(c) when c == '-' || isDigit(c) -> parseNum(p),
        Some(c) -> fail(p, "unexpected " ++ quoteChar(c)),
    }
}

pub fn parse(src: Str) -> Result<Val, (Int, Str)> {
    let p = P.{ src: chars(src), pos: [0] };
    let r = parseVal(p);
    match r {
        Ok(v) -> {
            skipWs(p);
            if isSome(peek(p)) { fail(p, "trailing input") } else { Ok(v) }
        },
        Err(e) -> Err(e),
    }
}

pub fn compact(v: Val) -> Str {
    match v {
        VNull -> "null",
        VBool(b) -> showBool(b),
        VNum(n) -> showInt(n),
        VStr(s) -> quoteStr(s),
        VArr(xs) -> "[" ++ strJoin(listMap(xs, |x| compact(x)), ",") ++ "]",
        VObj(fs) -> "{" ++ strJoin(listMap(fs, |f| quoteStr(fst(f)) ++ ":" ++ compact(snd(f))), ",") ++ "}",
    }
}

pub fn pretty(v: Val, ind: Int) -> Str {
    let pad = strRepeat("  ", ind + 1);
    let close = strRepeat("  ", ind);
    match v {
        VArr([]) -> "[]",
        VObj([]) -> "{}",
        VArr(xs) -> "[\n" ++ strJoin(listMap(xs, |x| pad ++ pretty(x, ind + 1)), ",\n") ++ "\n" ++ close ++ "]",
        VObj(fs) -> {
            let parts = listMap(fs, |f| { let (k, x) = f; pad ++ quoteStr(k) ++ ": " ++ pretty(x, ind + 1) });
            "{\n" ++ strJoin(parts, ",\n") ++ "\n" ++ close ++ "}"
        }
        other -> compact(other),
    }
}

pub fn count(v: Val) -> Int {
    match v {
        VArr(xs) -> listFold(xs, 1, |a, x| a + count(x)),
        VObj(fs) -> listFold(fs, 1, |a, f| a + count(snd(f))),
        _ -> 1,
    }
}
'''

PROGRAMS['bignum'] = r'''@module main
use big;

fn main() {
    var f = big::fromInt(1);
    for i in 1 .. 41 {
        f = big::mulSmall(f, i);
        if i % 10 == 0 { print(fmt("{}! = {}", [showInt(i), big::show(f)])); }
    }
    var a = big::fromInt(0);
    var b = big::fromInt(1);
    for i in 0 .. 150 {
        let c = big::add(a, b);
        a = b;
        b = c;
    }
    print("fib(150) = " ++ big::show(a));
    var p = big::fromInt(1);
    for i in 0 .. 128 { p = big::add(p, p); }
    print("2^128 = " ++ big::show(p));
    print("2^128 digits = " ++ showInt(big::digitCount(p)));
    let x = big::parse("123456789012345678901234567890");
    let y = big::parse("987654321098765432109876543210");
    print("x*y = " ++ big::show(big::mul(x, y)));
    print("x+y = " ++ big::show(big::add(x, y)));
    print("cmp = " ++ showInt(big::cmp(x, y)) ++ " " ++ showInt(big::cmp(y, x)) ++ " " ++ showInt(big::cmp(x, x)));
    print("y-x = " ++ big::show(big::sub(y, x)));
    print("zero = " ++ big::show(big::sub(x, x)));
    print(showBool(big::parse("000123") == big::fromInt(123)));
}
@module big
// Little-endian base-10000 limbs with no trailing zero limbs; zero is [].
pub struct Big { limbs: [Int] }

fn norm(xs: [Int]) -> Big {
    while listLen(xs) > 0 && listLast(xs) == 0 { pop(xs); }
    Big.{ limbs: xs }
}

pub fn fromInt(n: Int) -> Big {
    var xs: [Int] = listNew();
    var v = n;
    while v > 0 { push(xs, v % 10000); v = v / 10000; }
    norm(xs)
}

pub fn parse(s: Str) -> Big {
    var xs: [Int] = listNew();
    var end = strLen(s);
    while end > 0 {
        let start = maxI(0, end - 4);
        push(xs, unwrap(parseInt(substr(s, start, end))));
        end = start;
    }
    norm(xs)
}

pub fn show(b: Big) -> Str {
    let n = listLen(b.limbs);
    if n == 0 { return "0"; }
    var out = showInt(b.limbs[n - 1]);
    var i = n - 2;
    while i >= 0 {
        out = out ++ padLeft(showInt(b.limbs[i]), 4, '0');
        i = i - 1;
    }
    out
}

pub fn digitCount(b: Big) -> Int { strLen(show(b)) }

pub fn add(a: Big, b: Big) -> Big {
    var xs: [Int] = listNew();
    var carry = 0;
    let n = maxI(listLen(a.limbs), listLen(b.limbs));
    for i in 0 .. n {
        let s = carry + (if i < listLen(a.limbs) { a.limbs[i] } else { 0 })
                      + (if i < listLen(b.limbs) { b.limbs[i] } else { 0 });
        push(xs, s % 10000);
        carry = s / 10000;
    }
    if carry > 0 { push(xs, carry); }
    norm(xs)
}

// Requires a >= b.
pub fn sub(a: Big, b: Big) -> Big {
    var xs: [Int] = listNew();
    var borrow = 0;
    for i in 0 .. listLen(a.limbs) {
        var d = a.limbs[i] - borrow - (if i < listLen(b.limbs) { b.limbs[i] } else { 0 });
        if d < 0 { d = d + 10000; borrow = 1; } else { borrow = 0; }
        push(xs, d);
    }
    norm(xs)
}

pub fn mulSmall(a: Big, k: Int) -> Big {
    var xs: [Int] = listNew();
    var carry = 0;
    for l in a.limbs {
        let s = l * k + carry;
        push(xs, s % 10000);
        carry = s / 10000;
    }
    while carry > 0 { push(xs, carry % 10000); carry = carry / 10000; }
    norm(xs)
}

pub fn mul(a: Big, b: Big) -> Big {
    let n = listLen(a.limbs);
    let m = listLen(b.limbs);
    var xs = listRepeat(0, n + m + 1);
    for i in 0 .. n {
        var carry = 0;
        for j in 0 .. m {
            let s = xs[i + j] + a.limbs[i] * b.limbs[j] + carry;
            xs[i + j] = s % 10000;
            carry = s / 10000;
        }
        var k = i + m;
        while carry > 0 {
            let s = xs[k] + carry;
            xs[k] = s % 10000;
            carry = s / 10000;
            k = k + 1;
        }
    }
    norm(xs)
}

pub fn cmp(a: Big, b: Big) -> Int {
    let n = listLen(a.limbs);
    let m = listLen(b.limbs);
    if n != m { return cmpI(n, m); }
    var i = n - 1;
    while i >= 0 {
        if a.limbs[i] != b.limbs[i] { return cmpI(a.limbs[i], b.limbs[i]); }
        i = i - 1;
    }
    0
}
'''

PROGRAMS['life'] = r'''@module main
struct Board { w: Int, h: Int, cells: [Bool] }

fn at(b: Board, x: Int, y: Int) -> Bool {
    b.cells[modFloor(y, b.h) * b.w + modFloor(x, b.w)]
}

fn step(b: Board) -> Board {
    var next: [Bool] = listNew();
    for y in 0 .. b.h {
        for x in 0 .. b.w {
            var n = 0;
            for (dx, dy) in [(-1, -1), (0, -1), (1, -1), (-1, 0), (1, 0), (-1, 1), (0, 1), (1, 1)] {
                if at(b, x + dx, y + dy) { n = n + 1; }
            }
            let alive = at(b, x, y);
            push(next, match (alive, n) {
                (true, 2) -> true,
                (_, 3) -> true,
                _ -> false,
            });
        }
    }
    Board.{ w: b.w, h: b.h, cells: next }
}

fn render(b: Board) -> Str {
    var rows: [Str] = listNew();
    for y in 0 .. b.h {
        var cs: [Char] = listNew();
        for x in 0 .. b.w { push(cs, if at(b, x, y) { '#' } else { '.' }); }
        push(rows, strOfChars(cs));
    }
    strJoin(rows, "\n")
}

fn population(b: Board) -> Int { listLen(listFilter(b.cells, |c| c)) }

fn fromRows(rows: [Str]) -> Board {
    let h = listLen(rows);
    let w = strLen(rows[0]);
    var cells: [Bool] = listNew();
    for r in rows { for c in r { push(cells, c == '#'); } }
    Board.{ w: w, h: h, cells: cells }
}

fn main() {
    var b = fromRows([
        "....................",
        "..#.................",
        "...#................",
        ".###................",
        "....................",
        "..........###.......",
        "....................",
        "..............##....",
        "..............##....",
        "....................",
        "......#.............",
        ".....###............",
        "....................",
        "....................",
    ]);
    var pops: [Str] = listNew();
    var seen: #[Str: Int] = mapNew();
    var firstRepeat = -1;
    for gen in 0 .. 60 {
        push(pops, showInt(population(b)));
        let key = render(b);
        if mapHas(seen, key) && firstRepeat < 0 {
            firstRepeat = gen;
            print(fmt("state of gen {} repeats gen {}", [showInt(gen), showInt(seen[key])]));
        }
        seen[key] = gen;
        b = step(b);
    }
    print(strJoin(pops, " "));
    print(render(b));
    print("distinct states: " ++ showInt(mapLen(seen)));
}
'''

PROGRAMS['textstats'] = r'''@module main
fn words(text: Str) -> [Str] {
    var out: [Str] = listNew();
    var cur: [Char] = listNew();
    for c in text {
        if isAlpha(c) || c == '\'' {
            push(cur, toLowerC(c));
        } else if listLen(cur) > 0 {
            push(out, strOfChars(cur));
            clear(cur);
        }
    }
    if listLen(cur) > 0 { push(out, strOfChars(cur)); }
    out
}

fn mean(xs: [Int]) -> Float {
    toFloat(listFold(xs, 0, |a, x| a + x)) / toFloat(listLen(xs))
}

fn stddev(xs: [Int]) -> Float {
    let m = mean(xs);
    let ss = listFold(xs, 0.0, |a, x| a + (toFloat(x) - m) * (toFloat(x) - m));
    sqrtF(ss / toFloat(listLen(xs)))
}

fn main() {
    let text = "It was the best of times, it was the worst of times, it was the age of wisdom, it was the age of foolishness, it was the epoch of belief, it was the epoch of incredulity, it was the season of Light, it was the season of Darkness, it was the spring of hope, it was the winter of despair, we had everything before us, we had nothing before us, we were all going direct to Heaven, we were all going direct the other way -- in short, the period was so far like the present period, that some of its noisiest authorities insisted on its being received, for good or for evil, in the superlative degree of comparison only. There were a king with a large jaw and a queen with a plain face, on the throne of England; there were a king with a large jaw and a queen with a fair face, on the throne of France. It's clear.";
    let ws = words(text);
    var freq: #[Str: Int] = mapNew();
    for w in ws { freq[w] = mapGetOr(freq, w, 0) + 1; }
    print(fmt("words={} distinct={}", [showInt(listLen(ws)), showInt(mapLen(freq))]));
    let ranked = sortBy(pairsOf(freq), |a, b| {
        let c = cmpI(snd(b), snd(a));
        if c != 0 { c } else { strCmp(fst(a), fst(b)) }
    });
    for (w, n) in slice(ranked, 0, 12) {
        print(padRight(w, 10, '.') ++ padLeft(showInt(n), 4, ' ') ++ " " ++ strRepeat("*", n));
    }
    let lens = listMap(ws, |w| strLen(w));
    print("mean length " ++ showFloatAt(mean(lens), 4) ++ ", stddev " ++ showFloatAt(stddev(lens), 4));
    var byLen: #[Int: [Str]] = mapNew();
    for w in keysOf(freq) {
        let n = strLen(w);
        if !mapHas(byLen, n) { byLen[n] = listNew(); }
        push(byLen[n], w);
    }
    for n in sortBy(keysOf(byLen), |a, b| cmpI(a, b)) {
        let group = sortBy(byLen[n], |a, b| strCmp(a, b));
        if n >= 8 { print(showInt(n) ++ ": " ++ strJoin(group, " ")); }
    }
    let longest = listFold(ws, "", |best, w| if strLen(w) > strLen(best) { w } else { best });
    print("longest: " ++ longest ++ " reversed: " ++ strReverse(longest) ++ " upper: " ++ upper(longest));
    let vowels = listLen(listFilter(chars(text), |c| strContains("aeiouAEIOU", showChar(c))));
    print("vowel ratio " ++ showFloatAt(toFloat(vowels) / toFloat(strLen(text)), 6));
    print(strReplace(substr(text, 0, 48), "times", "TIMES"));
    print(showInt(strIndexOf(text, "epoch")) ++ " " ++ showInt(strLastIndexOf(text, "epoch")) ++ " " ++ showInt(listLen(strSplit(text, ", "))));
}
'''

PROGRAMS['closures'] = r'''@module main
fn compose<A, B, C>(f: fn(A) -> B, g: fn(B) -> C) -> fn(A) -> C {
    |x: A| g(f(x))
}

fn curry(f: fn(Int, Int) -> Int) -> fn(Int) -> fn(Int) -> Int {
    |a: Int| |b: Int| f(a, b)
}

fn memo(f: fn(fn(Int) -> Int, Int) -> Int) -> fn(Int) -> Int {
    let cache: #[Int: Int] = mapNew();
    let self_ref: [fn(Int) -> Int] = listNew();
    let go = |n: Int| -> Int {
        match mapGet(cache, n) {
            Some(v) -> v,
            None -> {
                let r = f(self_ref[0], n);
                cache[n] = r;
                r
            }
        }
    };
    push(self_ref, go);
    go
}

fn counterPair() -> (fn() -> Int, fn() -> Int) {
    let cell = [0];
    let inc = || { cell[0] = cell[0] + 1; cell[0] };
    let get = || cell[0];
    (inc, get)
}

fn applyN<T>(f: fn(T) -> T, n: Int, x: T) -> T {
    var v = x;
    for i in 0 .. n { v = f(v); }
    v
}

fn main() {
    let inc = |x: Int| x + 1;
    let dbl = |x: Int| x * 2;
    let both = compose(inc, dbl);
    let str2 = compose(both, |x: Int| "<" ++ showInt(x) ++ ">");
    print(str2(5) ++ " " ++ showInt(compose(dbl, inc)(5)));
    let add = curry(|a, b| a * 10 + b);
    let add3 = add(3);
    print(showInt(add3(4)) ++ " " ++ showInt(add(7)(1)));
    let calls = [0];
    let fib = memo(|rec, n| {
        calls[0] = calls[0] + 1;
        if n < 2 { n } else { rec(n - 1) + rec(n - 2) }
    });
    print("fib(80) = " ++ showInt(fib(80)) ++ " calls=" ++ showInt(calls[0]));
    print("fib(85) = " ++ showInt(fib(85)) ++ " calls=" ++ showInt(calls[0]));
    let (tick, read) = counterPair();
    tick(); tick();
    let t3 = tick();
    print(showInt(t3) ++ " " ++ showInt(read()));
    let (tick2, read2) = counterPair();
    tick2();
    print(showInt(read()) ++ " " ++ showInt(read2()));
    print(showInt(applyN(dbl, 10, 1)) ++ " " ++ applyN(|s: Str| s ++ "ab", 3, ">"));
    var adders: [fn(Int) -> Int] = listNew();
    var k = 0;
    while k < 5 {
        let kk = k;
        push(adders, |x: Int| x + kk * kk);
        k = k + 1;
    }
    print(strJoin(listMap(adders, |f| showInt(f(100))), ","));
    let pipeline = listFold(adders, |x: Int| x, |acc, f| compose(acc, f));
    print(showInt(pipeline(0)));
    let snapshot = k;
    let lateK = || snapshot + k;
    k = 1000;
    print(showInt(lateK()));
    let sorted = sortBy(["delta", "Alpha", "charlie", "Bravo"], |a, b| strCmp(lower(a), lower(b)));
    print(strJoin(sorted, " "));
    let counts: #[Char: Int] = mapNew();
    listMap(chars("mississippi"), |c| { counts[c] = mapGetOr(counts, c, 0) + 1; c });
    print(strJoin(listMap(pairsOf(counts), |p| showChar(fst(p)) ++ showInt(snd(p))), " "));
    let nested = |a: Int| |b: Int| |c: Int| a * 100 + b * 10 + c;
    print(showInt(nested(1)(2)(3)));
}
'''

PROGRAMS['search'] = r'''@module main
fn queens(n: Int, row: Int, cols: [Bool], d1: [Bool], d2: [Bool], place: [Int], sols: [[Int]]) -> Int {
    if row == n {
        if listLen(sols) < 3 { push(sols, listCopy(place)); }
        return 1;
    }
    var total = 0;
    for c in 0 .. n {
        let a = row + c;
        let b = row - c + n - 1;
        if !cols[c] && !d1[a] && !d2[b] {
            cols[c] = true; d1[a] = true; d2[b] = true;
            push(place, c);
            total = total + queens(n, row + 1, cols, d1, d2, place, sols);
            pop(place);
            cols[c] = false; d1[a] = false; d2[b] = false;
        }
    }
    total
}

fn countQueens(n: Int) -> (Int, [[Int]]) {
    let sols: [[Int]] = listNew();
    let t = queens(n, 0, listRepeat(false, n), listRepeat(false, 2 * n), listRepeat(false, 2 * n), listNew(), sols);
    (t, sols)
}

fn canPlace(g: [Int], pos: Int, v: Int) -> Bool {
    let r = pos / 9;
    let c = pos % 9;
    for i in 0 .. 9 {
        if g[r * 9 + i] == v || g[i * 9 + c] == v { return false; }
    }
    let br = r / 3 * 3;
    let bc = c / 3 * 3;
    for i in 0 .. 3 {
        for j in 0 .. 3 {
            if g[(br + i) * 9 + bc + j] == v { return false; }
        }
    }
    true
}

fn solve(g: [Int], steps: [Int]) -> Bool {
    let pos = listIndexOf(g, 0);
    if pos < 0 { return true; }
    for v in 1 .. 10 {
        if canPlace(g, pos, v) {
            g[pos] = v;
            steps[0] = steps[0] + 1;
            if solve(g, steps) { return true; }
            g[pos] = 0;
        }
    }
    false
}

fn permutations(xs: [Int]) -> [[Int]] {
    match xs {
        [] -> [[]],
        _ -> {
            var out: [[Int]] = listNew();
            for i in 0 .. listLen(xs) {
                let rest = slice(xs, 0, i) ++ slice(xs, i + 1, listLen(xs));
                for p in permutations(rest) {
                    push(out, [xs[i]] ++ p);
                }
            }
            out
        }
    }
}

fn main() {
    for n in 1 .. 9 {
        let (t, sols) = countQueens(n);
        let shown = listMap(sols, |s| strJoin(listMap(s, |c| showInt(c)), ""));
        print(fmt("queens({}) = {} first: {}", [showInt(n), showInt(t), strJoin(shown, " ")]));
    }
    let puzzle = "530070000600195000098000060800060003400803001700020006060000280000419005000080079";
    var g: [Int] = listMap(chars(puzzle), |c| ord(c) - 48);
    let steps = [0];
    print("solved: " ++ showBool(solve(g, steps)) ++ " placements: " ++ showInt(steps[0]));
    for r in 0 .. 9 {
        print(strJoin(listMap(slice(g, r * 9, r * 9 + 9), |v| showInt(v)), " "));
    }
    let ps = permutations([1, 2, 3, 4]);
    print(showInt(listLen(ps)) ++ " perms; last " ++ strJoin(listMap(listLast(ps), |v| showInt(v)), ""));
    let derangements = listFilter(ps, |p| listAll(listZip(p, [1, 2, 3, 4]), |q| fst(q) != snd(q)));
    print(showInt(listLen(derangements)) ++ " derangements: " ++ strJoin(listMap(derangements, |p| strJoin(listMap(p, |v| showInt(v)), "")), " "));
}
'''

PROGRAMS['machine'] = r'''@module main
enum Coin { Nickel, Dime, Quarter }
enum Cmd { Insert(Coin), Select(Str), Refund, Restock(Str, Int) }
enum State { Idle, Paying(Int) }
struct Item { name: Str, price: Int }

fn value(c: Coin) -> Int {
    match c { Nickel -> 5, Dime -> 10, Quarter -> 25 }
}

fn change(amount: Int) -> [Coin] {
    var left = amount;
    var out: [Coin] = listNew();
    for c in [Quarter, Dime, Nickel] {
        while left >= value(c) { push(out, c); left = left - value(c); }
    }
    out
}

fn coinName(c: Coin) -> Str {
    match c { Nickel -> "N", Dime -> "D", Quarter -> "Q" }
}

fn describeCoins(cs: [Coin]) -> Str {
    match cs {
        [] -> "nothing",
        [c] -> "one " ++ coinName(c),
        [a, b] -> "two: " ++ coinName(a) ++ coinName(b),
        [a, ..rest] -> coinName(a) ++ " and " ++ showInt(listLen(rest)) ++ " more",
    }
}

fn run(cmds: [Cmd], items: [Item], stock: #[Str: Int]) -> [Str] {
    var log: [Str] = listNew();
    var st = Idle;
    for cmd in cmds {
        let next = match (st, cmd) {
            (Idle, Insert(c)) -> Paying(value(c)),
            (Paying(n), Insert(c)) when n + value(c) > 100 -> {
                push(log, "rejected " ++ coinName(c));
                Paying(n)
            }
            (Paying(n), Insert(c)) -> Paying(n + value(c)),
            (Paying(n), Refund) -> {
                push(log, "refund " ++ describeCoins(change(n)));
                Idle
            }
            (Idle, Refund) -> { push(log, "nothing to refund"); Idle }
            (s, Restock(name, k)) -> {
                stock[name] = mapGetOr(stock, name, 0) + k;
                push(log, fmt("restocked {} to {}", [name, showInt(stock[name])]));
                s
            }
            (Idle, Select(name)) -> { push(log, "insert coins first"); Idle }
            (Paying(n), Select(name)) -> match listFind(items, |it| it.name == name) {
                None -> { push(log, "unknown " ++ quoteStr(name)); Paying(n) }
                Some(Item.{ price, .. }) when mapGetOr(stock, name, 0) == 0 -> {
                    push(log, name ++ " sold out (" ++ showInt(price) ++ ")");
                    Paying(n)
                }
                Some(it) when it.price > n -> {
                    push(log, fmt("need {} more for {}", [showInt(it.price - n), name]));
                    Paying(n)
                }
                Some(Item.{ name: nm, price: p }) -> {
                    stock[nm] = stock[nm] - 1;
                    push(log, fmt("vend {}, change {}", [nm, describeCoins(change(n - p))]));
                    Idle
                }
            },
        };
        st = next;
    }
    push(log, match st { Idle -> "end idle", Paying(n) -> "end holding " ++ showInt(n) });
    log
}

fn main() {
    let items = [Item.{ name: "cola", price: 65 }, Item.{ name: "chips", price: 40 }, Item.{ price: 15, name: "gum" }];
    var stock = #["cola": 1, "chips": 0, "gum": 5];
    let cmds = [
        Refund, Select("cola"), Insert(Quarter), Insert(Quarter), Select("cola"),
        Insert(Dime), Insert(Nickel), Select("cola"), Insert(Quarter), Insert(Quarter),
        Insert(Quarter), Select("cola"), Select("chips"), Restock("chips", 2), Select("chips"),
        Insert(Quarter), Insert(Quarter), Insert(Quarter), Insert(Quarter), Insert(Quarter),
        Select("tea"), Select("gum"), Insert(Dime), Refund, Insert(Nickel),
    ];
    for line in run(cmds, items, stock) { print(line); }
    print(strJoin(listMap(pairsOf(stock), |p| fst(p) ++ ":" ++ showInt(snd(p))), " "));
    print(describeCoins(change(95)) ++ " / " ++ describeCoins(change(35)) ++ " / " ++ describeCoins(change(0)) ++ " / " ++ describeCoins(change(10)));
}
'''

PROGRAMS['traits'] = r'''@module main
use geo;
use show as sh;

struct Tagged<T> { tag: Str, val: T }

impl<T: sh::Show> sh::Show for Tagged<T> {
    fn show(self) -> Str { self.tag ++ "=" ++ self.val.show() }
}

impl geo::Shape for Int {
    fn area(self) -> Int { self * self }
    fn name(self) -> Str { "square" ++ showInt(self) }
}

fn total<T: geo::Shape>(xs: [T]) -> Int { listFold(xs, 0, |a, x| a + x.area()) }

fn biggest<T: geo::Shape + sh::Show>(xs: [T]) -> Option<T> {
    var best: Option<T> = None;
    for x in xs {
        best = match best {
            None -> Some(x),
            Some(b) when x.area() > b.area() -> Some(x),
            keep -> keep,
        };
    }
    best
}

fn main() {
    let shapes = [geo::rect(3, 4), geo::circle(2), geo::tri(6, 5), geo::rect(5, 5)];
    for s in shapes {
        print(s.describe() ++ " | " ++ s.show());
    }
    print("total " ++ showInt(total(shapes)) ++ " / ints " ++ showInt(total([1, 2, 3])));
    print(biggest(shapes).show());
    let noFigs: [geo::Fig] = listNew();
    let none = biggest(noFigs);
    print(none.show());
    print([Tagged.{ tag: "a", val: 1 }, Tagged.{ tag: "b", val: -2 }].show());
    print(Tagged.{ tag: "nest", val: [Some("x"), None] }.show());
    let m = #["one": [1], "two": [2, 2]];
    print(m.show());
    print(7.describe());
    print(geo::circle(10).describe());
    print(sh::twice("ab".show()) ++ " " ++ true.show() ++ " " ++ 'c'.show() ++ " " ++ 1.5.show());
    let r: Result<Int, Str> = Err("bad");
    let ok: Result<Int, Str> = Ok(3);
    print(r.show() ++ " " ++ ok.show());
}
@module geo
use show;

pub enum Fig { Rect(Int, Int), Circle(Int), Tri(Int, Int) }

pub fn rect(w: Int, h: Int) -> Fig { Rect(w, h) }
pub fn circle(r: Int) -> Fig { Circle(r) }
pub fn tri(b: Int, h: Int) -> Fig { Tri(b, h) }

pub trait Shape {
    fn area(self) -> Int;
    fn name(self) -> Str { "shape" }
    fn describe(self) -> Str { self.name() ++ " with area " ++ showInt(self.area()) }
}

impl Shape for Fig {
    fn area(self) -> Int {
        match self {
            Rect(w, h) -> w * h,
            Circle(r) -> 314 * r * r / 100,
            Tri(b, h) -> b * h / 2,
        }
    }
    fn name(self) -> Str {
        match self { Rect(w, h) when w == h -> "square", Rect(_, _) -> "rect", Circle(_) -> "circle", Tri(_, _) -> "triangle" }
    }
}

impl show::Show for Fig {
    fn show(self) -> Str {
        match self {
            Rect(w, h) -> fmt("Rect({}, {})", [showInt(w), showInt(h)]),
            Circle(r) -> "Circle(" ++ showInt(r) ++ ")",
            Tri(b, h) -> "Tri(" ++ showInt(b) ++ ", " ++ showInt(h) ++ ")",
        }
    }
}
@module show
pub trait Show {
    fn show(self) -> Str;
}

pub fn twice(s: Str) -> Str { s ++ s }

impl Show for Int { fn show(self) -> Str { showInt(self) } }
impl Show for Str { fn show(self) -> Str { quoteStr(self) } }
impl Show for Bool { fn show(self) -> Str { showBool(self) } }
impl Show for Char { fn show(self) -> Str { quoteChar(self) } }
impl Show for Float { fn show(self) -> Str { showFloatAt(self, 2) } }

impl<T: Show> Show for [T] {
    fn show(self) -> Str { "[" ++ strJoin(listMap(self, |x| x.show()), ", ") ++ "]" }
}

impl<T: Show> Show for Option<T> {
    fn show(self) -> Str {
        match self { Some(x) -> "Some(" ++ x.show() ++ ")", None -> "None" }
    }
}

impl<T: Show, E: Show> Show for Result<T, E> {
    fn show(self) -> Str {
        match self { Ok(x) -> "Ok(" ++ x.show() ++ ")", Err(e) -> "Err(" ++ e.show() ++ ")" }
    }
}

impl<K: Key + Show, V: Show> Show for #[K: V] {
    fn show(self) -> Str {
        "#[" ++ strJoin(listMap(pairsOf(self), |p| fst(p).show() ++ ": " ++ snd(p).show()), ", ") ++ "]"
    }
}
'''

PROGRAMS['ledger_panic'] = r'''@module main
use ledger;

fn main() {
    let book = ledger::open(["cash", "bank", "rent", "food"]);
    let script = [
        ("bank", "cash", 200), ("cash", "food", 35), ("cash", "food", 12),
        ("bank", "rent", 900), ("cash", "food", 8), ("food", "cash", 5),
    ];
    for (from, to, amt) in script {
        ledger::post(book, from, to, amt);
        print(ledger::summary(book));
    }
    print("audit: " ++ showInt(ledger::audit(book)));
    ledger::post(book, "cash", "travel", 50);
    print("not reached");
}
@module ledger
pub struct Book { bal: #[Str: Int], hist: [(Str, Str, Int)] }

pub trait Report {
    fn line(self) -> Str;
}

impl Report for Book {
    fn line(self) -> Str {
        strJoin(listMap(pairsOf(self.bal), |p| fst(p) ++ "=" ++ showInt(snd(p))), " ")
    }
}

pub fn open(names: [Str]) -> Book {
    let m: #[Str: Int] = mapNew();
    for n in names { m[n] = 0; }
    Book.{ bal: m, hist: listNew() }
}

fn adjust(b: Book, who: Str, delta: Int) {
    let apply = |k: Str| { b.bal[k] = b.bal[k] + delta; };
    apply(who);
}

pub fn post(b: Book, from: Str, to: Str, amt: Int) {
    adjust(b, from, -amt);
    adjust(b, to, amt);
    push(b.hist, (from, to, amt));
}

pub fn summary(b: Book) -> Str { showInt(listLen(b.hist)) ++ ": " ++ b.line() }

pub fn audit(b: Book) -> Int {
    listFold(valuesOf(b.bal), 0, |a, v| a + v)
}
'''


def program_cases():
    expects = {'ledger_panic': 'panic'}
    for i, name in enumerate(PROGRAMS):
        add('program', name, PROGRAMS[name], True if i % 4 == 1 else None, expect=expects.get(name, 'ok'))


# @@GENERATED@@
# --- generated programs ---------------------------------------------------
#
# Every generator below is seeded with a fixed constant, so its output is the
# same on every run.  The programs are built to be well typed (their cases
# carry expect='ok'), except for the error-injection cases, which mutate a
# well-typed program on purpose.

BIG_LITERALS = ['9223372036854775807', '0x7fff_ffff', '0b1011_0110', '1_000_003',
                '4611686018427387904', '0xdead_beef', '123456789']


class IntProgGen:
    """Random well-typed programs over Int and Bool: functions with loops,
    matches, closures, tuples and library calls, spread over several modules
    that import each other.  Each function only calls functions generated
    before it, and a running cost estimate keeps the run time bounded."""

    def __init__(self, seed, nfuncs, nmods, budget=4000):
        self.r = random.Random(seed)
        self.nfuncs = nfuncs
        self.nmods = nmods
        self.budget = budget
        self.funcs = []
        self.locals_n = 0
        self.uses = {}

    def fresh(self):
        self.locals_n += 1
        return 'v%d' % self.locals_n

    def lit(self):
        r = self.r
        x = r.random()
        if x < 0.1:
            return r.choice(BIG_LITERALS)
        if x < 0.2:
            return 'intMin()' if r.random() < 0.5 else 'intMax()'
        return str(r.randint(0, 99))

    def leaf(self, env):
        if env and self.r.random() < 0.7:
            return self.r.choice(env)
        return self.lit()

    def callee_ref(self, f, mod):
        if f['mod'] == mod:
            return f['name']
        alias = self.uses.setdefault(mod, {}).setdefault(
            f['mod'], f['mod'] if self.r.random() < 0.6 else 'q' + f['mod'])
        return '%s::%s' % (alias, f['name'])

    def int_expr(self, env, depth, mod, cap):
        """Return (source, cost) of an Int expression."""
        r = self.r
        if depth <= 0:
            return self.leaf(env), 1
        k = r.randint(0, 17)
        sub = lambda: self.int_expr(env, depth - 1, mod, cap)
        if k <= 3:
            (a, ca), (b, cb) = sub(), sub()
            return '(%s %s %s)' % (a, r.choice(['+', '-', '*', '&', '|', '^']), b), ca + cb + 1
        if k == 4:
            (a, ca), (b, cb) = sub(), sub()
            fn = r.choice(['(%s / nz(%s))', '(%s %% nz(%s))', 'divFloor(%s, nz(%s))', 'modFloor(%s, nz(%s))'])
            return fn % (a, b), ca + cb + 3
        if k == 5:
            (a, ca), (b, cb) = sub(), sub()
            return '(%s %s (%s & 63))' % (a, r.choice(['<<', '>>']), b), ca + cb + 1
        if k == 6:
            a, ca = sub()
            return r.choice(['(~%s)', '(-%s)', 'absI(%s)', 'signI(%s)', 'popCount(%s)',
                             'clz(%s)', 'ctz(%s)', 'strLen(showInt(%s))']) % a, ca + 1
        if k == 7:
            (a, ca), (b, cb) = sub(), sub()
            return '%s(%s, %s)' % (r.choice(['minI', 'maxI', 'gcdI']), a, b), ca + cb + 1
        if k == 8:
            c, cc = self.bool_expr(env, depth - 1, mod, cap)
            (a, ca), (b, cb) = sub(), sub()
            return '(if %s { %s } else { %s })' % (c, a, b), cc + ca + cb
        if k == 9:
            s, cs = sub()
            (a, ca), (b, cb) = sub(), sub()
            v = self.fresh()
            c, cc = self.int_expr(env + [v], depth - 1, mod, cap)
            return ('(match %s & 3 { 0 -> %s, 1 -> %s, %s -> %s })'
                    % (s, a, b, v, c)), cs + ca + cb + cc
        if k <= 11:
            cands = [f for f in self.funcs if f['cost'] <= cap
                     and (f['mod'] == mod or f['pub'])]
            if cands:
                f = r.choice(cands[-12:])
                args, cost = [], f['cost'] + 2
                for _ in range(f['arity']):
                    a, ca = sub()
                    args.append(a)
                    cost += ca
                return '%s(%s)' % (self.callee_ref(f, mod), ', '.join(args)), cost
            return sub()
        if k == 12:
            (a, ca), (b, cb), (c, cc) = sub(), sub(), sub()
            (i0, ci) = self.int_expr(env, depth - 1, mod, cap)
            op = r.choice(['+', '^', '-', '|'])
            return ('listFold([%s, %s, %s], %s, |acc, x| acc %s x)'
                    % (a, b, c, i0, op)), ca + cb + cc + ci + 8
        if k == 13:
            v = self.fresh()
            a, ca = sub()
            b, cb = self.int_expr(env + [v], depth - 1, mod, cap)
            return '(match %s { %s -> %s })' % (a, v, b), ca + cb + 1
        if k == 14:
            (a, ca), (b, cb) = sub(), sub()
            return '%s((%s, %s))' % (r.choice(['fst', 'snd']), a, b), ca + cb + 2
        if k == 15:
            (a, ca), (b, cb), (i, ci) = sub(), sub(), sub()
            return '[%s, %s][%s & 1]' % (a, b, i), ca + cb + ci + 2
        if k == 16:
            (a, ca), (b, cb) = sub(), sub()
            v = self.fresh()
            return ('(match |y: Int| y * 3 + %s { %s -> %s(%s) })' % (a, v, v, b)), ca + cb + 4
        a, ca = sub()
        return ('unwrapOr(parseInt(showInt(%s)), 0)' % a), ca + 3

    def bool_expr(self, env, depth, mod, cap):
        r = self.r
        k = r.randint(0, 5)
        if depth <= 0 or k == 0:
            (a, ca), (b, cb) = self.int_expr(env, 0, mod, cap), self.int_expr(env, 0, mod, cap)
            return '(%s %s %s)' % (a, r.choice(['<', '<=', '>', '>=', '==', '!=']), b), ca + cb
        if k <= 2:
            (a, ca), (b, cb) = (self.int_expr(env, depth - 1, mod, cap),
                                self.int_expr(env, depth - 1, mod, cap))
            return '(%s %s %s)' % (a, r.choice(['<', '<=', '>', '>=', '==', '!=']), b), ca + cb + 1
        if k == 3:
            (a, ca), (b, cb) = (self.bool_expr(env, depth - 1, mod, cap),
                                self.bool_expr(env, depth - 1, mod, cap))
            return '(%s %s %s)' % (a, r.choice(['&&', '||']), b), ca + cb + 1
        if k == 4:
            a, ca = self.bool_expr(env, depth - 1, mod, cap)
            return '(!%s)' % a, ca + 1
        a, ca = self.int_expr(env, depth - 1, mod, cap)
        return '(%s & 1 == 0)' % a, ca + 1

    def gen_func(self, idx, mod):
        r = self.r
        arity = r.randint(0, 4)
        params = ['a', 'b', 'c', 'd'][:arity]
        name = 'f%d' % idx
        env = list(params)
        cap = self.budget // 8
        lines, cost = [], 0
        depth = r.randint(1, 3)
        e, c = self.int_expr(env, depth, mod, cap)
        lines.append('var acc = %s;' % e)
        cost += c
        env.append('acc')
        for _ in range(r.randint(1, 4)):
            kind = r.randint(0, 5)
            if kind == 0:
                v = self.fresh()
                e, c = self.int_expr(env, depth, mod, cap)
                lines.append('let %s = %s;' % (v, e))
                env.append(v)
                cost += c
            elif kind == 1:
                n = r.randint(1, 8)
                v = self.fresh()
                e, c = self.int_expr(env + [v], depth, mod, cap // 4)
                lines.append('for %s in 0 .. %d { acc = acc %s %s; }'
                             % (v, n, r.choice(['+', '^', '-']), e))
                cost += n * (c + 3)
            elif kind == 2:
                n = r.randint(1, 6)
                v = self.fresh()
                cnd, cc = self.bool_expr(env + [v], 1, mod, cap // 4)
                e, c = self.int_expr(env + [v], depth, mod, cap // 4)
                lines.append('var %s = 0;' % v)
                lines.append('while %s < %d {' % (v, n))
                lines.append('    if %s { acc = acc + %s; } else { acc = acc - %s; }' % (cnd, v, e))
                lines.append('    %s = %s + 1;' % (v, v))
                lines.append('}')
                cost += n * (c + cc + 5)
            elif kind == 3:
                cnd, cc = self.bool_expr(env, depth, mod, cap)
                e, c = self.int_expr(env, depth, mod, cap)
                lines.append('if %s { return %s; }' % (cnd, e))
                cost += cc + c
            elif kind == 4:
                e, c = self.int_expr(env, depth, mod, cap)
                lines.append('match acc & 3 {')
                lines.append('    0 -> { acc = acc + %s; }' % e)
                lines.append('    2 -> acc = acc * 3;' if False else '    2 -> { acc = acc * 3; }')
                lines.append('    _ -> {}')
                lines.append('}')
                cost += c + 3
            else:
                n = r.randint(2, 5)
                v = self.fresh()
                e, c = self.int_expr(env + [v], depth, mod, cap // 4)
                lines.append('for %s in listMap([%s], |t| t * 2) {' % (v, ', '.join(str(r.randint(-9, 9)) for _ in range(n))))
                lines.append('    if %s > 0 { continue; }' % v)
                lines.append('    acc = acc ^ %s;' % e)
                lines.append('    if acc < 0 { break; }')
                lines.append('}')
                cost += n * (c + 6)
        e, c = self.int_expr(env, depth, mod, cap)
        lines.append('acc %s %s' % (r.choice(['+', '^', '-']), e))
        cost += c
        pub = r.random() < 0.8
        f = {'name': name, 'mod': mod, 'arity': arity, 'cost': cost + 2, 'pub': pub,
             'src': '%sfn %s(%s) -> Int {\n%s\n}\n' % (
                 'pub ' if pub else '', name,
                 ', '.join('%s: Int' % p for p in params),
                 '\n'.join('    ' + l for l in lines))}
        self.funcs.append(f)

    def build(self):
        r = self.r
        mods = ['main'] + ['m%d' % i for i in range(1, self.nmods)]
        for i in range(self.nfuncs):
            # Later functions live in earlier modules, so imports form cycles.
            self.gen_func(i, r.choice(mods))
        body = []
        for f in self.funcs:
            if f['cost'] > self.budget or not (f['pub'] or f['mod'] == 'main'):
                continue
            args = ', '.join(str(r.randint(-50, 50)) for _ in range(f['arity']))
            body.append('print("%s = " ++ showInt(%s(%s)));'
                        % (f['name'], self.callee_ref(f, 'main'), args))
        cheap = [f for f in self.funcs if f['cost'] * 20 <= self.budget and f['pub']]
        if cheap:
            f = cheap[-1]
            args = ', '.join(['k', 'k * k', '7 - k', 'k ^ 5'][:f['arity']])
            body.append('var check = 0;')
            body.append('for k in 0 .. 20 { check = check * 31 + %s(%s); }'
                        % (self.callee_ref(f, 'main'), args))
            body.append('print("check " ++ showInt(check));')
        out = []
        for m in mods:
            out.append('@module %s\n' % m)
            for dep, alias in sorted(self.uses.get(m, {}).items()):
                out.append('use %s;\n' % dep if alias == dep else 'use %s as %s;\n' % (dep, alias))
            out.append('fn nz(x: Int) -> Int { if x == 0 { 1 } else { x } }\n')
            for f in self.funcs:
                if f['mod'] == m:
                    out.append(f['src'])
            if m == 'main':
                out.append('fn main() {\n%s\n}\n' % '\n'.join('    ' + b for b in body))
        return ''.join(out)


def libfuzz_program(seed, nops, panic_at_end=False):
    """Random sequences of list, map and string operations, each followed by a
    one-line print of the state it touched.  Every index and count is computed
    so that it is in range, so the run ends normally unless `panic_at_end`."""
    r = random.Random(seed)
    words = ['ab', 'cd', 'abc', 'x', '', 'hello', 'ab,cd', 'é', 'z9', 'q q']
    w = lambda: '"%s"' % r.choice(words)
    ops = [
        lambda: 'push(xs, %d);' % r.randint(-99, 99),
        lambda: 'if listLen(xs) > 0 { emit("pop " ++ showInt(pop(xs)) ++ " "); }',
        lambda: 'insert(xs, modFloor(%d, listLen(xs) + 1), %d);' % (r.randint(0, 50), r.randint(-9, 9)),
        lambda: 'if listLen(xs) > 0 { emit("rm " ++ showInt(removeAt(xs, modFloor(%d, listLen(xs)))) ++ " "); }' % r.randint(0, 50),
        lambda: 'xs = sortBy(xs, |p, q| cmpI(%sp, %sq));' % ((r.choice(['', '-']),) * 2),
        lambda: 'xs = listFilter(xs, |v| v %% %d != 0);' % r.randint(2, 5),
        lambda: 'xs = listMap(xs, |v| v * %d %% 101);' % r.randint(2, 9),
        lambda: 'xs = reverseList(xs);',
        lambda: 'xs = xs ++ slice(xs, 0, listLen(xs) / 2);',
        lambda: 'ys = listCopy(xs); push(ys, 1000);',
        lambda: 'm[%s] = listLen(xs);' % w(),
        lambda: 'emit(showBool(mapDel(m, %s)) ++ " ");' % w(),
        lambda: 'm[%s] = mapGetOr(m, %s, 0) + %d;' % (w(), w(), r.randint(1, 5)),
        lambda: 'for k in keysOf(m) { if m[k] % 2 == 0 { m[k] = m[k] + 1; } }',
        lambda: 's = s ++ %s;' % w(),
        lambda: 's = strReplace(s, %s, %s);' % (r.choice(['"ab"', '"x"', '"c"', '"é"']), w()),
        lambda: 's = strJoin(strSplit(s, %s), "/");' % r.choice(['"a"', '","', '"/"', '" "']),
        lambda: 's = substr(s, minI(%d, strLen(s)), strLen(s));' % r.randint(0, 3),
        lambda: 's = if strLen(s) > 40 { strReverse(substr(s, 0, 20)) } else { s };',
        lambda: 's = upper(s);' if r.random() < 0.5 else 's = lower(s);',
        lambda: 'emit(showInt(strIndexOf(s, %s)) ++ "," ++ showInt(strLastIndexOf(s, %s)) ++ " ");' % (w(), w()),
        lambda: 'for c in chars(%s) { push(cs, c); }' % w(),
        lambda: 'if listLen(cs) > 0 { cs = sortBy(cs, |p, q| cmpC(q, p)); emit(strOfChars(cs) ++ " "); }',
        lambda: 'emit(showBool(listContains(xs, %d)) ++ showInt(listIndexOf(xs, %d)) ++ " ");' % (r.randint(-9, 9), r.randint(-9, 9)),
    ]
    lines = ['var xs: [Int] = listNew();', 'var ys: [Int] = listNew();',
             'var m: #[Str: Int] = mapNew();', 'var s = "start";',
             'var cs: [Char] = listNew();']
    for i in range(nops):
        lines.append(r.choice(ops)())
        lines.append('print(fmt("{} xs={} ys={} m={} s={}", [showInt(%d), sl(xs), showInt(listLen(ys)), sm(m), quoteStr(s)]));' % i)
    lines.append('print(showInt(listFold(xs, 0, |a, v| a * 7 + v)) ++ " " ++ showInt(mapLen(m)) ++ " " ++ showInt(strLen(s)));')
    if panic_at_end:
        lines.append(r.choice([
            'print(showInt(xs[listLen(xs)]));',
            'print(showInt(m["missing-key"]));',
            'clear(xs); print(showInt(pop(xs)));',
            'print(substr(s, 0, strLen(s) + 1));',
        ]))
    src = ('@module main\n'
           'fn sl(xs: [Int]) -> Str { "[" ++ strJoin(listMap(xs, |v| showInt(v)), ",") ++ "]" }\n'
           'fn sm(m: #[Str: Int]) -> Str {\n'
           '    "{" ++ strJoin(listMap(pairsOf(m), |p| quoteStr(fst(p)) ++ ":" ++ showInt(snd(p))), ",") ++ "}"\n'
           '}\n'
           'fn main() {\n' + ''.join('    %s\n' % l for l in lines) + '}\n')
    return src


SHOW_FN = {'Int': 'showInt', 'Bool': 'showBool', 'Color': 'dc', 'Shape': 'ds',
           'Opt': 'dopt', 'List': 'dl'}


class MatchGen:
    """Random enums with nested payloads, random values of them, and random
    matches with nested, tuple, list, literal and guard patterns."""

    def __init__(self, seed):
        self.r = random.Random(seed)

    def enum_decls(self):
        return ('enum Color { Red, Green, Blue }\n'
                'enum Shape { Dot, Seg(Int), Box(Int, Int), Tagged(Color, Shape) }\n'
                'fn dc(c: Color) -> Str { match c { Red -> "R", Green -> "G", Blue -> "B" } }\n'
                'fn ds(s: Shape) -> Str {\n'
                '    match s {\n'
                '        Dot -> ".",\n'
                '        Seg(n) -> "S" ++ showInt(n),\n'
                '        Box(a, b) -> "B" ++ showInt(a) ++ "x" ++ showInt(b),\n'
                '        Tagged(c, t) -> dc(c) ++ "<" ++ ds(t) ++ ">",\n'
                '    }\n'
                '}\n'
                'fn dopt(o: Option<Shape>) -> Str { match o { Some(s) -> "?" ++ ds(s), None -> "-" } }\n'
                'fn dl(xs: [Int]) -> Str { "[" ++ strJoin(listMap(xs, |v| showInt(v)), " ") ++ "]" }\n')

    def value(self, ty, depth):
        r = self.r
        if ty == 'Int':
            return str(r.randint(-3, 3))
        if ty == 'Bool':
            return r.choice(['true', 'false'])
        if ty == 'Color':
            return r.choice(['Red', 'Green', 'Blue'])
        if ty == 'Shape':
            k = r.randint(0, 3 if depth > 0 else 2)
            if k == 0:
                return 'Dot'
            if k == 1:
                return 'Seg(%s)' % self.value('Int', depth)
            if k == 2:
                return 'Box(%s, %s)' % (self.value('Int', depth), self.value('Int', depth))
            return 'Tagged(%s, %s)' % (self.value('Color', depth), self.value('Shape', depth - 1))
        if ty == 'Opt':
            return 'None' if r.random() < 0.3 else 'Some(%s)' % self.value('Shape', depth)
        if ty == 'List':
            return '[%s]' % ', '.join(self.value('Int', depth) for _ in range(r.randint(0, 4)))
        raise ValueError(ty)

    def pattern(self, ty, depth, binds):
        r = self.r
        if r.random() < 0.2 or depth <= 0:
            if r.random() < 0.5:
                return '_'
            v = 'p%d' % len(binds)
            binds.append((v, ty))
            return v
        if ty == 'Int':
            return str(r.randint(-2, 2))
        if ty == 'Bool':
            return r.choice(['true', 'false'])
        if ty == 'Color':
            return r.choice(['Red', 'Green', 'Blue'])
        if ty == 'Shape':
            k = r.randint(0, 3)
            if k == 0:
                return 'Dot'
            if k == 1:
                return 'Seg(%s)' % self.pattern('Int', depth - 1, binds)
            if k == 2:
                return 'Box(%s, %s)' % (self.pattern('Int', depth - 1, binds),
                                        self.pattern('Int', depth - 1, binds))
            return 'Tagged(%s, %s)' % (self.pattern('Color', depth - 1, binds),
                                       self.pattern('Shape', depth - 1, binds))
        if ty == 'Opt':
            return 'None' if r.random() < 0.3 else 'Some(%s)' % self.pattern('Shape', depth - 1, binds)
        if ty == 'List':
            n = r.randint(0, 2)
            elems = [self.pattern('Int', depth - 1, binds) for _ in range(n)]
            if r.random() < 0.5:
                if r.random() < 0.5:
                    v = 'rest%d' % len(binds)
                    binds.append((v, 'List'))
                    elems.append('..' + v)
                else:
                    elems.append('..')
            return '[%s]' % ', '.join(elems)
        raise ValueError(ty)

    def match_fn(self, name, tys, narms, catch_all):
        r = self.r
        params = ', '.join('x%d: %s' % (i, 'Option<Shape>' if t == 'Opt' else '[Int]' if t == 'List' else t)
                           for i, t in enumerate(tys))
        scrut = 'x0' if len(tys) == 1 else '(%s)' % ', '.join('x%d' % i for i in range(len(tys)))
        arms = []
        for i in range(narms):
            binds = []
            pats = [self.pattern(t, 3, binds) for t in tys]
            pat = pats[0] if len(pats) == 1 else '(%s)' % ', '.join(pats)
            guard = ''
            if binds and r.random() < 0.3:
                guard = ' when %s' % r.choice(['true', 'false', 'showInt(%d) != ""' % i])
            body = '"%d"' % i
            if binds:
                body = '"%d:" ++ %s' % (i, ' ++ "," ++ '.join(
                    '%s(%s)' % (SHOW_FN[t], v) for v, t in binds))
            arms.append('        %s%s -> %s,' % (pat, guard, body))
        if catch_all:
            arms.append('        _ -> "other",')
        return 'fn %s(%s) -> Str {\n    match %s {\n%s\n    }\n}\n' % (name, params, scrut, '\n'.join(arms))

    def program(self, nfuncs, nvals, catch_all=True):
        r = self.r
        type_sets = [['Shape'], ['Color', 'Bool'], ['Opt'], ['List'], ['Shape', 'Int'],
                     ['Bool', 'Bool', 'Color'], ['List', 'Bool'], ['Opt', 'Color']]
        funcs, calls = [], []
        for i in range(nfuncs):
            tys = r.choice(type_sets)
            funcs.append((tys, self.match_fn('g%d' % i, tys, r.randint(2, 7), catch_all)))
        for i, (tys, _) in enumerate(funcs):
            for _ in range(nvals):
                args = ', '.join(self.value(t, 3) for t in tys)
                calls.append('    emit(g%d(%s) ++ " ");' % (i, args))
            calls.append('    print("");')
        return ('@module main\n' + self.enum_decls() + ''.join(f for _, f in funcs)
                + 'fn main() {\n' + '\n'.join(calls) + '\n}\n')


def fixed_match_program(seed, nfuncs, nvals):
    """A MatchGen program whose unreachable arms have been removed, using the
    reference to find them, so the run exercises matching at run time."""
    g = MatchGen(seed)
    src = g.program(nfuncs, nvals)
    for _ in range(200):
        out = run_reference(src)
        m = re.fullmatch(r'error: unreachable at (\d+):(\d+)\n', out)
        if not m:
            return src
        lines = src.split('\n')
        # Module-local line L is whole-input line L + 1 (one header line).
        del lines[int(m.group(1))]
        src = '\n'.join(lines)
    raise RuntimeError('could not fix match program')


def exhaust_program(seed):
    """One random match with no catch-all arm: the reference decides whether it
    is exhaustive, has an unreachable arm, or neither."""
    g = MatchGen(seed)
    r = g.r
    tys = r.choice([['Shape'], ['Color', 'Bool'], ['Opt'], ['List'], ['Bool', 'Bool', 'Color'],
                    ['List', 'Bool'], ['Opt', 'Color'], ['Shape', 'Bool']])
    fn = g.match_fn('g', tys, r.randint(3, 9), False)
    args = ', '.join(g.value(t, 2) for t in tys)
    return ('@module main\n' + g.enum_decls() + fn
            + 'fn main() {\n    print(g(%s));\n}\n' % args)


def inject_error(src, seed, kind):
    """Mutate a well-typed generated program so that it is rejected."""
    r = random.Random(seed)
    lines = src.split('\n')
    body_lines = [i for i, l in enumerate(lines)
                  if l.startswith('    ') and not l.strip().startswith(('}', 'match', '0 ->', '2 ->', '_ ->'))]
    need = {'unknown_name': lambda l: re.search(r'\bacc\b', l),
            'type_mismatch': lambda l: '(' in l, 'two_errors': lambda l: '(' in l,
            'parse': lambda l: ';' in l or ')' in l,
            'int_range': lambda l: '0' in l}.get(kind, lambda l: True)
    i = r.choice([k for k in body_lines if need(lines[k])])
    l = lines[i]
    if kind == 'unknown_name':
        lines[i] = re.sub(r'\bacc\b', 'acx', l, count=1)
    elif kind == 'type_mismatch':
        j = l.find('(')
        lines[i] = l[:j + 1] + '"s" + ' + l[j + 1:]
    elif kind == 'parse':
        j = [k for k, ch in enumerate(l) if ch in ';)']
        k = r.choice(j)
        lines[i] = l[:k] + l[k + 1:]
    elif kind == 'bad_token':
        k = r.randint(4, len(l))
        lines[i] = l[:k] + '$' + l[k:]
    elif kind == 'int_range':
        lines[i] = l.replace('0', '9223372036854775808', 1)
    elif kind == 'dup_name':
        fns = [k for k, x in enumerate(lines) if x.startswith(('fn f', 'pub fn f'))]
        k = r.choice(fns)
        end = lines.index('}', k)
        lines[end + 1:end + 1] = lines[k:end + 1]
    elif kind == 'not_public':
        pubs = [k for k, x in enumerate(lines) if x.startswith('pub fn f')]
        k = r.choice(pubs)
        lines[k] = lines[k][4:]
    elif kind == 'two_errors':
        # A type error early in the stream and a lexing error later: the lexing
        # error is reported because pass 1 runs before pass 4.
        j = l.find('(')
        lines[i] = l[:j + 1] + 'true + ' + l[j + 1:]
        k = max(body_lines)
        lines[k] = lines[k] + ' \'ab\''
    elif kind == 'unterminated':
        k = max(body_lines)
        lines[k] = lines[k] + ' /* never closed'
    else:
        raise ValueError(kind)
    return '\n'.join(lines)


MINI_TEMPLATES = [
    'let s = 0; let i = 1; while i <= {n} {{ s = s + i * i; i = i + 1; }} print s;',
    'let a = {a}; let b = {b}; while b != 0 {{ let t = b; b = a - a / b * b; a = t; }} print a;',
    'let n = {n}; let f = 1; while n > 1 {{ f = f * n; n = n - 1; }} print f;',
    'let x = {a}; let steps = 0; while x != 1 {{ if x - x / 2 * 2 == 0 {{ x = x / 2; }} else {{ x = 3 * x + 1; }} steps = steps + 1; }} print steps;',
    'let p = 0; let q = 1; let k = 0; while k < {n} {{ let t = p + q; p = q; q = t; k = k + 1; }} print p; print q;',
    'let c = 0; let i = 2; while i < {n} {{ let j = 2; let prime = 1; while j * j <= i {{ if i - i / j * j == 0 {{ prime = 0; }} j = j + 1; }} c = c + prime; i = i + 1; }} print c;',
    'let v = {a} * {b} - ({a} + {b}) / 3; print v; if v > {n} {{ print 1; }} else {{ print 0; }}',
    'let x = {a}; print x / ({b} - {b});',
    'print zz{n};',
    'let y = ({a} + {b}; print y;',
    'let m = {a}; let r = 0; while m > 0 {{ r = r * 10 + (m - m / 10 * 10); m = m / 10; }} print r;',
    'let w = 0; while 1 {{ w = w + 1; }} print w;',
]


def mini_programs(seed, count, scale):
    r = random.Random(seed)
    progs = []
    for _ in range(count):
        t = r.choice(MINI_TEMPLATES)
        progs.append(t.format(n=r.randint(2, scale), a=r.randint(1, 30 * scale), b=r.randint(1, 50)))
    return progs


def interp_program(progs, guard=1000, width=46):
    """The four-module interpreter program with the given mini-programs."""
    src = PROGRAMS['interp']
    head, tail = src.split('    let progs = [\n', 1)
    tail = tail.split('    ];\n', 1)[1]
    plist = ''.join('        %s,\n' % json_quote(p) for p in progs)
    src = head + '    let progs = [\n' + plist + '    ];\n' + tail
    src = src.replace('padRight(p, 46, \'.\')', 'padRight(p, %d, \'.\')' % width)
    return src.replace('if guard > 1000 {', 'if guard > %d {' % guard)


def json_quote(s):
    return '"' + s.replace('\\', '\\\\').replace('"', '\\"') + '"'


def generated_cases():
    # Random Int programs of growing size; the largest spread over many modules.
    sizes = [(101, 4, 1), (102, 8, 2), (104, 24, 4), (106, 70, 10), (108, 200, 24)]
    for seed, nf, nm in sizes:
        src = IntProgGen(seed, nf, nm).build()
        add('gen', 'intprog_%d_f%d_m%d' % (seed, nf, nm), src, expect='ok')
    # Error injection into generated programs: the first error in pass order.
    kinds = ['unknown_name', 'type_mismatch', 'parse', 'bad_token', 'int_range',
             'dup_name', 'not_public', 'two_errors']
    for i, kind in enumerate(kinds):
        base = IntProgGen(300 + i, 30 + 10 * i, 3 + i % 4).build()
        add('gen', 'inject_%s' % kind, inject_error(base, 900 + i, kind), expect='error')
    # Library operation fuzz.
    for i, (n, pan) in enumerate([(15, False), (80, True), (300, True)]):
        add('gen', 'libfuzz_%d_%d' % (i, n), libfuzz_program(500 + i, n, pan),
            expect='panic' if pan else 'ok')
    # Pattern matching at run time.
    for i, (nf, nv) in enumerate([(8, 6), (20, 10)]):
        add('gen', 'matchprog_%d' % i, fixed_match_program(700 + i, nf, nv), expect='ok')
    # Random exhaustiveness and reachability verdicts.
    for i in range(3):
        add('gen', 'exhaust_rand_%d' % i, exhaust_program(800 + i))
    # The interpreter program over generated mini-programs.
    for i, (cnt, scale) in enumerate([(30, 20)]):
        add('gen', 'interp_%d' % i, interp_program(mini_programs(601 + i, cnt, scale), width=60),
            expect='ok')


# @@HEAVY@@
# --- heavy workloads ------------------------------------------------------
#
# Each of these sits near the section 18.3 ceiling of about 3e7 VM
# instructions (a few seconds in the Python reference).

HEAVY = {}

HEAVY['fib'] = '''@module main
fn fib(n: Int) -> Int { if n < 2 { n } else { fib(n - 1) + fib(n - 2) } }
fn main() {
    for n in [0, 1, 2, 10, 20] { emit(showInt(fib(n)) ++ " "); }
    print("");
    print(showInt(fib(28)));
}
'''

HEAVY['sort_lcg'] = '''@module main
struct Rec { key: Int, id: Int }

fn main() {
    var seed = 12345;
    var xs: [Rec] = listNew();
    for i in 0 .. 60000 {
        seed = (seed * 6364136223846793005 + 1442695040888963407) & intMax();
        push(xs, Rec.{ key: seed % 1000, id: i });
    }
    let calls = [0];
    let sorted = sortBy(xs, |a, b| { calls[0] = calls[0] + 1; cmpI(a.key, b.key) });
    var check = 0;
    var stable = true;
    for i in 0 .. listLen(sorted) {
        check = check * 31 + sorted[i].id;
        if i > 0 && sorted[i - 1].key == sorted[i].key && sorted[i - 1].id > sorted[i].id {
            stable = false;
        }
    }
    print("calls " ++ showInt(calls[0]));
    print("check " ++ showInt(check));
    print("stable " ++ showBool(stable));
    print("first " ++ showInt(sorted[0].id) ++ " last " ++ showInt(listLast(sorted).id));
    let ints = listMap(xs, |r| r.id * 7919 % 100003);
    let desc = sortBy(ints, |a, b| cmpI(b, a));
    print(strJoin(listMap(slice(desc, 0, 8), |v| showInt(v)), " "));
}
'''

HEAVY['map_count'] = '''@module main
fn main() {
    var counts: #[Int: Int] = mapNew();
    var words: #[Str: Int] = mapNew();
    var x = 7;
    for i in 0 .. 120000 {
        x = (x * 1103515245 + 12345) % 2147483648;
        let k = x % 5000;
        counts[k] = mapGetOr(counts, k, 0) + 1;
        if i % 3 == 0 { mapDel(counts, (k * 7) % 5000); }
        if i % 5 == 0 {
            let w = "w" ++ showInt(k % 300);
            words[w] = mapGetOr(words, w, 0) + k;
        }
    }
    print(showInt(mapLen(counts)) ++ " " ++ showInt(mapLen(words)));
    let ks = keysOf(counts);
    print(strJoin(listMap(slice(ks, 0, 10), |k| showInt(k)), ","));
    print(showInt(listFold(valuesOf(counts), 0, |a, v| a + v)));
    var best = "";
    var bestV = -1;
    for (w, v) in pairsOf(words) {
        if v > bestV { best = w; bestV = v; }
    }
    print(best ++ " " ++ showInt(bestV));
}
'''

HEAVY['sieve'] = '''@module main
fn main() {
    let n = 400000;
    var comp = listRepeat(false, n + 1);
    var primes: [Int] = listNew();
    for i in 2 .. n + 1 {
        if !comp[i] {
            push(primes, i);
            var j = i * i;
            while j <= n {
                comp[j] = true;
                j = j + i;
            }
        }
    }
    print(showInt(listLen(primes)) ++ " primes, last " ++ showInt(listLast(primes)));
    var twins = 0;
    for k in 1 .. listLen(primes) {
        if primes[k] - primes[k - 1] == 2 { twins = twins + 1; }
    }
    print(showInt(twins) ++ " twin pairs");
}
'''

HEAVY['string_scan'] = '''@module main
fn main() {
    let unit = "the quick brown fox jumps over the lazy dog; ";
    let text = strRepeat(unit, 6000);
    let n = strLen(text);
    var vowels = 0;
    var spaces = 0;
    var hash = 0;
    for i in 0 .. n {
        let c = charAt(text, i);
        if strContains("aeiou", showChar(c)) { vowels = vowels + 1; }
        if c == ' ' { spaces = spaces + 1; }
        hash = (hash * 131 + ord(c)) % 1000000007;
    }
    print(fmt("{} chars, {} vowels, {} spaces, hash {}", [showInt(n), showInt(vowels), showInt(spaces), showInt(hash)]));
    let parts = strSplit(text, "; ");
    print(showInt(listLen(parts)) ++ " parts");
    var rev = 0;
    for c in strReverse(substr(text, 0, 90000)) { if c == 'o' { rev = rev + 1; } }
    print(showInt(rev) ++ " o's in the reversed prefix");
    print(showInt(strIndexOf(text, "dog; the quick brown fox jumps over the lazy cat")));
}
'''

HEAVY['deep_methods'] = '''@module main
trait Walk {
    fn walk(self, n: Int) -> Int;
}

struct Stepper { by: Int }

impl Walk for Stepper {
    fn walk(self, n: Int) -> Int {
        if n == 0 { 0 } else { self.by + self.walk(n - 1) }
    }
}

fn viaClosure(n: Int) -> Int {
    let f = |k: Int| if k == 0 { 0 } else { viaClosure(k - 1) + 1 };
    f(n)
}

fn main() {
    print(showInt(Stepper.{ by: 3 }.walk(14000)));
    print(showInt(viaClosure(7000)));
}
'''

HEAVY['frames_exact'] = '''@module main
fn down(n: Int) -> Int { if n == 0 { return 0; } down(n - 1) + 1 }
fn main() { print(showInt(down(19998))); }
'''

HEAVY['frames_over_by_one'] = '''@module main
fn down(n: Int) -> Int { if n == 0 { return 0; } down(n - 1) + 1 }
fn main() {
    print("start");
    print(showInt(down(19999)));
}
'''


def heavy_cases():
    expects = {'frames_over_by_one': 'panic'}
    for i, name in enumerate(HEAVY):
        add('heavy', name, HEAVY[name], True if i % 4 == 0 else None, expect=expects.get(name, 'ok'))
    big = IntProgGen(4242, 360, 40, budget=6000).build()
    add('heavy', 'intprog_huge', big, False, expect='ok')
    add('heavy', 'interp_long', interp_program(mini_programs(4343, 90, 60), guard=20000, width=70),
        True, expect='ok')
    add('heavy', 'matchprog_big', fixed_match_program(4444, 40, 40), False, expect='ok')


# --- driver ---------------------------------------------------------------

def outcome(out):
    """Classify an expected output: a diagnostic kind, 'panic' or 'ok'."""
    lines = out.rstrip('\n').split('\n')
    m = re.fullmatch(r'error: ([a-z-]+) at \d+:\d+', lines[0]) if len(lines) == 1 else None
    if m:
        return 'error ' + m.group(1)
    if lines[-1].startswith('panic: '):
        return 'panic'
    return 'ok'


def build_cases():
    spec_examples()
    hand_1()
    hand_2()
    hand_3()
    hand_4()
    hand_5()
    hand_6()
    hand_7()
    hand_8()
    hand_9()
    library_sweeps()
    panic_cases()
    inference_limit_cases()
    program_cases()
    generated_cases()
    heavy_cases()


def main():
    from concurrent.futures import ThreadPoolExecutor
    build_cases()
    order = ordered_cases()
    if '--list' in sys.argv:
        for n, i in enumerate(order, 1):
            c = CASES[i]
            print('%03d %-8s %-40s %s' % (n, c['area'], c['name'],
                                          {True: 'public?', False: 'hidden', None: '-'}[c['pub']]))
        return
    only = None
    if '--only' in sys.argv:
        only = sys.argv[sys.argv.index('--only') + 1]
    jobs = [i for i in order if only is None or only in CASES[i]['name']]
    with ThreadPoolExecutor(max_workers=os.cpu_count() or 4) as pool:
        outs = dict(zip(jobs, pool.map(lambda i: run_reference(CASES[i]['src']), jobs)))
    if only is not None:
        for i in jobs:
            print('==', CASES[i]['name'], outcome(outs[i]))
            print(outs[i][:2000])
        return
    assign_visibility(outs)
    clean_dir(PUBLIC_DIR)
    clean_dir(HIDDEN_DIR)
    counts = [0, 0]
    for n, i in enumerate(order, 1):
        c = CASES[i]
        must = c.get('expect')
        got = outcome(outs[i])
        if must is not None and not got.startswith(must):
            raise RuntimeError('case %s: expected %s, got %s'
                               % (c['name'], must, outs[i][:300]))
        d = PUBLIC_DIR if c['pub'] else HIDDEN_DIR
        counts[0 if c['pub'] else 1] += 1
        base = os.path.join(d, '%03d_%s_%s' % (n, c['area'], c['name']))
        with open(base + '.in', 'w', encoding='utf-8', newline='') as f:
            f.write(c['src'])
        with open(base + '.out', 'w', encoding='utf-8', newline='') as f:
            f.write(outs[i])
        print('%03d %-8s %-36s %-7s %s' % (n, c['area'], c['name'],
                                           'public' if c['pub'] else 'hidden', got))
    print('public %d, hidden %d, total %d' % (counts[0], counts[1], sum(counts)))


if __name__ == '__main__':
    main()
