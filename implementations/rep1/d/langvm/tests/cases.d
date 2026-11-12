/// Generated end-to-end cases; see e2e.d for the runner.
module cases;

struct Case
{
    string name;
    string source;
    string expected;
}

/// The worked examples of SPEC.md section 17.
immutable Case[] specExamples = [
    Case("example 1: modules, imports and visibility", q"VELLUM
@module main
use greet;

fn main() {
    print(greet::hello("Vellum"));
    print(greet::hello("world"));
}
@module greet
pub fn hello(who: Str) -> Str {
    "hello, " ++ who ++ "!"
}

fn secret() -> Int { 42 }
VELLUM",
         "hello, Vellum!\nhello, world!\n"),
    Case("example 2: recursion, loops, early return", q"VELLUM
@module main
fn fact(n: Int) -> Int {
    if n <= 1 { return 1; }
    n * fact(n - 1)
}

fn firstDivisor(n: Int) -> Int {
    var d = 2;
    while d * d <= n {
        if n % d == 0 { return d; }
        d = d + 1;
    }
    n
}

fn main() {
    print(showInt(fact(10)));
    for i in 2 .. 12 {
        if i % 2 == 0 { continue; }
        emit(showInt(firstDivisor(i)));
        emit(" ");
    }
    print("");
    var total = 0;
    for x in [3, 1, 4, 1, 5, 9, 2, 6] {
        if x == 9 { break; }
        total = total + x;
    }
    print(showInt(total));
}
VELLUM",
         "3628800\n3 5 7 3 11 \n14\n"),
    Case("example 3: structs, generics, Option, let patterns", q"VELLUM
@module main
struct Pair<A, B> { left: A, right: B }

struct Point { x: Int, y: Int }

fn swap<A, B>(p: Pair<A, B>) -> Pair<B, A> {
    Pair.{ left: p.right, right: p.left }
}

fn lookup(xs: [Point], x: Int) -> Option<Point> {
    for p in xs {
        if p.x == x { return Some(p); }
    }
    None
}

fn main() {
    let p = Pair.{ left: 7, right: "seven" };
    let q = swap(p);
    print(fmt("{} {}", [q.left, showInt(q.right)]));
    let pts = [Point.{ x: 1, y: 10 }, Point.{ x: 2, y: 20 }];
    match lookup(pts, 2) {
        Some(pt) -> print(fmt("found y={}", [showInt(pt.y)])),
        None -> print("none"),
    }
    let r: Option<Point> = lookup(pts, 5);
    print(showBool(isNone(r)));
    let Pair.{ left: l, right: rr } = p;
    print(fmt("{}/{}", [showInt(l), rr]));
}
VELLUM",
         "seven 7\nfound y=20\ntrue\n7/seven\n"),
    Case("example 4: sum types, guards, nested and list patterns", q"VELLUM
@module main
enum Shape {
    Circle(Int),
    Rect(Int, Int),
    Group([Shape]),
    Empty,
}

fn area(s: Shape) -> Int {
    match s {
        Circle(r) when r <= 0 -> 0,
        Circle(r) -> 3 * r * r,
        Rect(w, h) -> w * h,
        Group([]) -> 0,
        Group([only]) -> area(only),
        Group([first, ..rest]) -> area(first) + area(Group(rest)),
        Empty -> 0,
    }
}

fn describe(s: Shape) -> Str {
    match s {
        Rect(w, h) when w == h -> "square",
        Rect(_, _) -> "rect",
        Circle(_) -> "circle",
        Group([Circle(_), ..]) -> "group starting with a circle",
        Group(_) -> "group",
        Empty -> "nothing",
    }
}

fn main() {
    let shapes = [Circle(2), Circle(-1), Rect(3, 4), Rect(5, 5), Empty,
                  Group([Circle(1), Rect(2, 2)])];
    for s in shapes {
        print(fmt("{} {}", [padRight(describe(s), 29, '.'), showInt(area(s))]));
    }
}
VELLUM",
         "circle....................... 12\ncircle....................... 0\nrect......................... 12\nsquare....................... 25\nnothing...................... 0\ngroup starting with a circle. 7\n"),
    Case("example 5: traits, impls, default methods, generic bounds", q"VELLUM
@module main
use shapes;

trait Render {
    fn render(self) -> Str;
    fn tag(self) -> Str { "?" }
}

impl Render for Int {
    fn render(self) -> Str { showInt(self) }
    fn tag(self) -> Str { "int" }
}

impl Render for Str {
    fn render(self) -> Str { quoteStr(self) }
}

impl<T: Render> Render for [T] {
    fn render(self) -> Str {
        let parts = listMap(self, |x| x.render());
        "[" ++ strJoin(parts, ", ") ++ "]"
    }
    fn tag(self) -> Str { "list" }
}

impl Render for shapes::Box {
    fn render(self) -> Str { fmt("{}x{}", [showInt(self.w), showInt(self.h)]) }
}

fn show2<T: Render>(x: T) -> Str {
    fmt("{}:{}", [x.tag(), x.render()])
}

fn main() {
    print(show2(42));
    print(show2("hi"));
    print(show2([1, 2, 3]));
    print(show2(shapes::mk(3, 4)));
    print(Render::render([["a"], ["b", "c"]]));
}
@module shapes
pub struct Box { w: Int, h: Int }

pub fn mk(w: Int, h: Int) -> Box { Box.{ w: w, h: h } }
VELLUM",
         "int:42\n?:\"hi\"\nlist:[1, 2, 3]\n?:3x4\n[[\"a\"], [\"b\", \"c\"]]\n"),
    Case("example 6: closures", q"VELLUM
@module main
fn counter(start: Int) -> fn(Int) -> Int {
    var base = start;
    let f = |d: Int| base + d;
    base = base + 100;
    f
}

fn main() {
    let f = counter(1);
    print(showInt(f(5)));

    var fs: [fn() -> Int] = listNew();
    for i in 0 .. 4 {
        push(fs, || i * i);
    }
    var acc = 0;
    for g in fs {
        acc = acc + g();
    }
    print(showInt(acc));

    let xs = [5, 3, 8, 1];
    print(strJoin(listMap(sortBy(xs, |a, b| cmpI(a, b)), |v| showInt(v)), ","));
    print(showInt(listFold(xs, 0, |a, x| a + x)));

    let shared = [1, 2];
    let grow = || push(shared, 3);
    grow();
    print(showInt(listLen(shared)));
}
VELLUM",
         "6\n14\n1,3,5,8\n17\n3\n"),
    Case("example 7: maps and deterministic order", q"VELLUM
@module main
fn main() {
    var counts = #["pear": 1];
    counts["apple"] = 2;
    counts["pear"] = counts["pear"] + 10;
    counts["fig"] = 0;
    mapDel(counts, "apple");
    counts["apple"] = 7;
    for k in keysOf(counts) {
        emit(fmt("{}={} ", [k, showInt(counts[k])]));
    }
    print("");
    print(showInt(mapLen(counts)));
    print(showBool(mapHas(counts, "plum")));
    print(showInt(unwrapOr(mapGet(counts, "plum"), -1)));
    let a = #[1: "x", 2: "y"];
    let b = #[2: "y", 1: "x"];
    print(showBool(a == b));
    for (k, v) in pairsOf(a) {
        emit(fmt("{}{} ", [showInt(k), v]));
    }
    print("");
}
VELLUM",
         "pear=11 fig=0 apple=7 \n3\nfalse\n-1\ntrue\n1x 2y \n"),
    Case("example 8: integers", q"VELLUM
@module main
fn main() {
    print(showInt(intMax() + 1));
    print(showInt(intMin() - 1));
    print(showInt(-7 / 2) ++ " " ++ showInt(-7 % 2));
    print(showInt(divFloor(-7, 2)) ++ " " ++ showInt(modFloor(-7, 2)));
    print(showInt(7 / -2) ++ " " ++ showInt(7 % -2));
    print(showInt(intMin() / -1));
    print(showIntRadix(255, 16) ++ " " ++ showIntRadix(-255, 2));
    print(showInt(1 << 62) ++ " " ++ showInt(-16 >> 2));
    print(showInt(0x0f & 0x1c) ++ " " ++ showInt(5 | 2) ++ " " ++ showInt(~0));
    print(showInt(powI(3, 20)) ++ " " ++ showInt(gcdI(-84, 36)));
    print(showInt(popCount(255)) ++ " " ++ showInt(clz(1)) ++ " " ++ showInt(ctz(8)));
    print(showBool(parseInt("x") == None));
    print(showInt(unwrapOr(parseInt("-0042"), 0)));
}
VELLUM",
         "-9223372036854775808\n9223372036854775807\n-3 -1\n-4 1\n-3 1\n-9223372036854775808\nff -11111111\n4611686018427387904 -4\n12 7 -1\n3486784401 12\n8 63 3\ntrue\n-42\n"),
    Case("example 9: floats", q"VELLUM
@module main
fn main() {
    print(showFloat(1.0));
    print(showFloat(2.0 / 3.0));
    print(showFloat(-0.0));
    print(showFloatAt(2.5, 0) ++ " " ++ showFloatAt(3.5, 0) ++ " " ++ showFloatAt(0.5, 0));
    print(showFloatAt(0.1 + 0.2, 17));
    print(showFloatAt(1.0 / 3.0, 10));
    print(showFloat(sqrtF(2.0)));
    print(showFloat(piF()));
    print(showFloatAt(nanF(), 2) ++ " " ++ showFloatAt(1.0 / 0.0, 2)
          ++ " " ++ showFloatAt(-1.0 / 0.0, 2));
    print(showInt(floatBits(1.0)));
    print(showFloat(powF(2.0, 10)) ++ " " ++ showFloat(powF(2.0, -2)));
    print(showInt(truncToInt(-3.9)) ++ " " ++ showFloat(roundF(-2.5))
          ++ " " ++ showFloat(floorF(-2.5)));
    print(showBool(nanF() == nanF()) ++ " " ++ showInt(cmpF(nanF(), 1.0)));
    print(showFloat(toFloat(9007199254740993)));
}
VELLUM",
         "1.000000\n0.666667\n-0.000000\n2 4 0\n0.30000000000000004\n0.3333333333\n1.414214\n3.141593\nnan inf -inf\n4607182418800017408\n1024.000000 0.250000\n-3 -3.000000 -3.000000\nfalse 1\n9007199254740992.000000\n"),
    Case("example 10: strings and characters", q"VELLUM
@module main
fn main() {
    let s = "héllo, wörld";
    print(showInt(strLen(s)));
    print(showChar(charAt(s, 1)) ++ showChar(charAt(s, 8)));
    print(substr(s, 7, 12));
    print(upper(s));
    print(strJoin(strSplit("a,,b,", ","), "|"));
    print(strReplace("aaa", "aa", "b"));
    print(fmt("[{}] [{}]", [padLeft("7", 3, '0'), padRight("x", 3, '-')]));
    print(quoteStr("tab\there\n"));
    print(showInt(strIndexOf(s, "l")) ++ " " ++ showInt(strLastIndexOf(s, "l"))
          ++ " " ++ showInt(strIndexOf(s, "z")));
    print(strReverse("abc") ++ " " ++ trim("  pad  ") ++ "!");
    print(strOfChars([chr(86), 'e', 'l']));
    print(showInt(strCmp("abc", "abd")) ++ showInt(strCmp("ab", "ab"))
          ++ showInt(strCmp("b", "ab")));
    print(showBool(isSpace('\t')) ++ " " ++ quoteChar('\''));
}
VELLUM",
         "12\néö\nwörld\nHéLLO, WöRLD\na||b|\nba\n[007] [x--]\n\"tab\\there\\n\"\n2 10 -1\ncba pad!\nVel\n-101\ntrue '\\''\n"),
    Case("example 11: a runtime panic after output", q"VELLUM
@module main
fn get(xs: [Int], i: Int) -> Int { xs[i] }

fn main() {
    let xs = [10, 20, 30];
    print(showInt(get(xs, 2)));
    print(showInt(get(xs, 3)));
    print("never reached");
}
VELLUM",
         "30\npanic: index out of bounds\n"),
    Case("example 12: a type error, with its exact position", q"VELLUM
@module main
fn main() {
    let n: Int = 1;
    print(n + "x");
}
VELLUM",
         "error: type-mismatch at 3:15\n"),
    Case("example 13: a non-exhaustive match", q"VELLUM
@module main
enum Colour { Red, Green, Blue }

fn name(c: Colour) -> Str {
    match c {
        Red -> "red",
        Green -> "green",
    }
}

fn main() { print(name(Blue)); }
VELLUM",
         "error: non-exhaustive at 4:5\n"),
    Case("example 14: an unsatisfied bound", q"VELLUM
@module main
trait Area { fn area(self) -> Int; }

struct Sq { s: Int }

fn total<T: Area>(xs: [T]) -> Int {
    var sum = 0;
    for x in xs { sum = sum + x.area(); }
    sum
}

fn main() {
    print(showInt(total([Sq.{ s: 3 }])));
}
VELLUM",
         "error: unsatisfied-bound at 12:19\n"),
    Case("example 15: which error is reported", q"VELLUM
@module main
fn main() {
    let x: Int = "s";
}
@module other
fn f( {
}
VELLUM",
         "error: parse at 1:7\n"),
    Case("example 16: a bigger program", q"VELLUM
@module main
enum Tok { Num(Int), Var(Str), Op(Char) }

fn tokenize(src: Str) -> [Tok] {
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
        } else if isAlpha(c) {
            var j = i;
            while j < n && isAlnum(charAt(src, j)) { j = j + 1; }
            push(out, Var(substr(src, i, j)));
            i = j;
        } else {
            push(out, Op(c));
            i = i + 1;
        }
    }
    out
}

fn evalRpn(toks: [Tok], env: #[Str: Int]) -> Result<Int, Str> {
    var stack: [Int] = listNew();
    for t in toks {
        match t {
            Num(v) -> push(stack, v),
            Var(name) -> match mapGet(env, name) {
                Some(v) -> push(stack, v),
                None -> { return Err("unbound " ++ name); }
            },
            Op(c) -> {
                if listLen(stack) < 2 { return Err("stack underflow"); }
                let b = pop(stack);
                let a = pop(stack);
                match c {
                    '+' -> push(stack, a + b),
                    '-' -> push(stack, a - b),
                    '*' -> push(stack, a * b),
                    '/' -> if b == 0 { return Err("divide by zero"); }
                           else { push(stack, a / b) },
                    _ -> { return Err("bad op " ++ showChar(c)); }
                }
            },
        }
    }
    if listLen(stack) == 1 { Ok(listLast(stack)) } else { Err("leftover") }
}

fn main() {
    let env = #["x": 10, "y": 4];
    let progs = ["3 4 +", "x y -", "2 3 4 * +", "x 0 /", "z 1 +", "1 2",
                 "5 1 2 + 4 * + 3 -"];
    for p in progs {
        match evalRpn(tokenize(p), env) {
            Ok(v) -> print(fmt("{} => {}", [p, showInt(v)])),
            Err(e) -> print(fmt("{} => error: {}", [p, e])),
        }
    }
}
VELLUM",
         "3 4 + => 7\nx y - => 6\n2 3 4 * + => 14\nx 0 / => error: divide by zero\nz 1 + => error: unbound z\n1 2 => error: leftover\n5 1 2 + 4 * + 3 - => 14\n"),
    Case("example 17: error: assign-immutable at 3:5", q"VELLUM
@module main
fn main() {
    let x = 1;
    x = 2;
}
VELLUM",
         "error: assign-immutable at 3:5\n"),
    Case("example 17: error: cannot-infer at 2:14", q"VELLUM
@module main
fn main() {
    var xs = [];
}
VELLUM",
         "error: cannot-infer at 2:14\n"),
    Case("example 17: error: unreachable at 4:9", q"VELLUM
@module main
fn main() {
    match 3 {
        _ -> print("a"),
        1 -> print("b"),
    }
}
VELLUM",
         "error: unreachable at 4:9\n"),
    Case("example 17: error: ambig-method at 8:21", q"VELLUM
@module main
trait A { fn go(self) -> Int; }
trait B { fn go(self) -> Int; }

impl A for Int { fn go(self) -> Int { 1 } }
impl B for Int { fn go(self) -> Int { 2 } }

fn main() {
    print(showInt(3.go()));
}
VELLUM",
         "error: ambig-method at 8:21\n"),
    Case("example 17: error: unknown-name at 2:19", q"VELLUM
@module main
fn main() {
    print(showInt(len([1, 2])));
}
VELLUM",
         "error: unknown-name at 2:19\n"),
    Case("example 17: error: missing-return at 1:1", q"VELLUM
@module main
fn f() -> Int {
    let x = 1;
}

fn main() { print(showInt(f())); }
VELLUM",
         "error: missing-return at 1:1\n"),
    Case("example 17: error: missing-field at 4:13", q"VELLUM
@module main
struct S { a: Int, b: Int }

fn main() {
    let s = S.{ a: 1 };
    print(showInt(s.a));
}
VELLUM",
         "error: missing-field at 4:13\n"),
    Case("example 17: error: not-eq at 5:20", q"VELLUM
@module main
fn main() {
    let t = (1, "two");
    print(showBool(t == (1, "two")));
    let f = |x: Int| x;
    print(showBool(f == f));
}
VELLUM",
         "error: not-eq at 5:20\n"),
    Case("example 17: error: not-iterable at 2:14", q"VELLUM
@module main
fn main() {
    for c in 'a' { print(showChar(c)); }
}
VELLUM",
         "error: not-iterable at 2:14\n"),
    Case("example 17: error: bad-key-type at 2:15", q"VELLUM
@module main
fn main() {
    let m = #[1.5: "x"];
}
VELLUM",
         "error: bad-key-type at 2:15\n"),
];

/// Additional cases covering the language rules and every error kind.
immutable Case[] ruleCases = [
    Case("lone-return-unit-val", q"VELLUM
@module main
fn f() { return 5; }
fn main() { f(); }
VELLUM",
         "error: type-mismatch at 1:10\n"),
    Case("closure-nested", q"VELLUM
@module main
fn main() {
  let a = 1;
  let f = |x: Int| { let g = |y: Int| a + x + y; g(10) };
  print(showInt(f(100)));
}
VELLUM",
         "111\n"),
    Case("self-capture", q"VELLUM
@module main
trait T { fn go(self) -> Int; }
impl T for Int { fn go(self) -> Int { let f = || self + 1; f() } }
fn main() { print(showInt(5.go())); }
VELLUM",
         "6\n"),
    Case("default-calls-other", q"VELLUM
@module main
trait T { fn a(self) -> Int; fn b(self) -> Int { self.a() * 2 } }
impl T for Str { fn a(self) -> Int { strLen(self) } }
fn main() { print(showInt("abc".b())); }
VELLUM",
         "6\n"),
    Case("generic-bound-user", q"VELLUM
@module main
trait Sh { fn area(self) -> Int; }
struct Sq { s: Int }
impl Sh for Sq { fn area(self) -> Int { self.s * self.s } }
fn tot<T: Sh>(xs: [T]) -> Int { var t = 0; for x in xs { t = t + x.area(); } t }
fn main() { print(showInt(tot([Sq.{ s: 2 }, Sq.{ s: 3 }]))); }
VELLUM",
         "13\n"),
    Case("struct-order", q"VELLUM
@module main
struct P { a: Int, b: Int }
fn f(x: Int) -> Int { print(showInt(x)); x }
fn main() { let p = P.{ b: f(1), a: f(2) }; print(showInt(p.a * 10 + p.b)); }
VELLUM",
         "1\n2\n21\n"),
    Case("str-pattern", q"VELLUM
@module main
fn f(s: Str) -> Int { match s { "a" -> 1, "b" -> 2, _ -> 3 } }
fn main() { print(showInt(f("a") + f("b") * 10 + f("z") * 100)); }
VELLUM",
         "321\n"),
    Case("nested-opt", q"VELLUM
@module main
fn main() { let x: Option<Option<Int>> = Some(Some(3)); match x { Some(Some(n)) -> print(showInt(n)), Some(None) -> print("sn"), None -> print("n") } }
VELLUM",
         "3\n"),
    Case("list-rest", q"VELLUM
@module main
fn main() { match [1,2,3,4] { [a, b, ..r] -> print(showInt(a+b+listLen(r))), _ -> print("x") } }
VELLUM",
         "5\n"),
    Case("tuple-let", q"VELLUM
@module main
fn main() { let (a, b) = (1, "x"); print(showInt(a) ++ b); }
VELLUM",
         "1x\n"),
    Case("shadow-prelude", q"VELLUM
@module main
fn print(x: Int) { emit("int:" ++ showInt(x) ++ "\n"); }
fn main() { print(5); }
VELLUM",
         "int:5\n"),
    Case("map-iter", q"VELLUM
@module main
fn main() { let m = #["a": 1, "b": 2]; for (k, v) in pairsOf(m) { emit(k ++ showInt(v)); } print(""); }
VELLUM",
         "a1b2\n"),
    Case("while-break", q"VELLUM
@module main
fn main() { var i = 0; while true { i = i + 1; if i > 5 { break; } } print(showInt(i)); }
VELLUM",
         "6\n"),
    Case("break-in-expr", q"VELLUM
@module main
fn f(x: Int) -> Int { x }
fn main() { var i = 0; var s = 0; while i < 5 { i = i + 1; s = s + f(match i { 3 -> { continue; }, _ -> i }); } print(showInt(s)); }
VELLUM",
         "12\n"),
    Case("float-cmp", q"VELLUM
@module main
fn main() { print(showBool(1.5 < 2.5) ++ showBool(nanF() == nanF()) ++ showBool(-0.0 == 0.0)); }
VELLUM",
         "truefalsetrue\n"),
    Case("method-on-list", q"VELLUM
@module main
trait L { fn n(self) -> Int; }
impl<T> L for [T] { fn n(self) -> Int { listLen(self) } }
fn main() { print(showInt([1,2,3].n())); }
VELLUM",
         "3\n"),
    Case("enum-method", q"VELLUM
@module main
enum C { R, G }
trait N { fn nm(self) -> Str; }
impl N for C { fn nm(self) -> Str { match self { R -> "red", G -> "green" } } }
fn main() { print(G.nm() ++ R.nm()); }
VELLUM",
         "greenred\n"),
    Case("div-zero", q"VELLUM
@module main
fn main() { print("a"); print(showInt(1 / (1 - 1))); }
VELLUM",
         "a\npanic: divide by zero\n"),
    Case("emit-panic", q"VELLUM
@module main
fn main() { emit("a"); panic("boom"); }
VELLUM",
         "apanic: boom\n"),
    Case("stack", q"VELLUM
@module main
fn f(n: Int) -> Int { if n == 0 { 0 } else { 1 + f(n - 1) } }
fn main() { print(showInt(f(19998))); print(showInt(f(19999))); }
VELLUM",
         "19998\npanic: call stack overflow\n"),
    Case("reserved", q"VELLUM
@module main
struct Int { a: Int }
fn main() {}
VELLUM",
         "error: reserved-name at 1:8\n"),
    Case("dup-fn", q"VELLUM
@module main
fn a() {}
fn a() {}
fn main() {}
VELLUM",
         "error: dup-name at 2:4\n"),
    Case("dup-variant-fn", q"VELLUM
@module main
enum E { A }
fn A() {}
fn main() {}
VELLUM",
         "error: dup-name at 2:4\n"),
    Case("unknown-module-use", q"VELLUM
@module main
use zz;
fn main() {}
VELLUM",
         "error: unknown-module at 1:5\n"),
    Case("dup-import", q"VELLUM
@module main
use main;
use main;
fn main() {}
VELLUM",
         "error: dup-name at 2:5\n"),
    Case("dup-tparam", q"VELLUM
@module main
fn f<T, T>() {}
fn main() {}
VELLUM",
         "error: dup-name at 1:9\n"),
    Case("dup-param", q"VELLUM
@module main
fn f(a: Int, a: Int) {}
fn main() {}
VELLUM",
         "error: dup-name at 1:14\n"),
    Case("unknown-type", q"VELLUM
@module main
fn f(a: Nope) {}
fn main() {}
VELLUM",
         "error: unknown-type at 1:9\n"),
    Case("unknown-trait", q"VELLUM
@module main
fn f<T: Nope>(a: T) {}
fn main() {}
VELLUM",
         "error: unknown-trait at 1:9\n"),
    Case("arity-type", q"VELLUM
@module main
fn f(a: Option) {}
fn main() {}
VELLUM",
         "error: arity-type at 1:9\n"),
    Case("arity-type-prim", q"VELLUM
@module main
fn f(a: Int<Int>) {}
fn main() {}
VELLUM",
         "error: arity-type at 1:9\n"),
    Case("bad-key-type", q"VELLUM
@module main
fn f(a: #[Float: Int]) {}
fn main() {}
VELLUM",
         "error: bad-key-type at 1:9\n"),
    Case("self-outside", q"VELLUM
@module main
fn f(a: Self) {}
fn main() {}
VELLUM",
         "error: self-outside at 1:9\n"),
    Case("builtin-impl", q"VELLUM
@module main
struct S {}
impl Eq for S {}
fn main() {}
VELLUM",
         "error: builtin-trait-impl at 2:1\n"),
    Case("bad-impl-head", q"VELLUM
@module main
trait T { fn f(self); }
impl T for [Int] { fn f(self) {} }
fn main() {}
VELLUM",
         "error: bad-impl-head at 2:12\n"),
    Case("unused-param", q"VELLUM
@module main
trait T { fn f(self); }
impl<A> T for Int { fn f(self) {} }
fn main() {}
VELLUM",
         "error: unused-param at 2:6\n"),
    Case("dup-impl", q"VELLUM
@module main
trait T { fn f(self); }
impl T for Int { fn f(self) {} }
impl T for Int { fn f(self) {} }
fn main() {}
VELLUM",
         "error: dup-impl at 3:1\n"),
    Case("missing-method", q"VELLUM
@module main
trait T { fn f(self); }
impl T for Int { }
fn main() {}
VELLUM",
         "error: missing-method at 2:1\n"),
    Case("extra-method", q"VELLUM
@module main
trait T { fn f(self); }
impl T for Int { fn f(self) {} fn g(self) {} }
fn main() {}
VELLUM",
         "error: extra-method at 2:35\n"),
    Case("sig-mismatch", q"VELLUM
@module main
trait T { fn f(self) -> Int; }
impl T for Int { fn f(self) -> Str { "" } }
fn main() {}
VELLUM",
         "error: sig-mismatch at 2:21\n"),
    Case("no-main", q"VELLUM
@module main
fn f() {}
VELLUM",
         "error: no-main at 1:1\n"),
    Case("no-main2", q"VELLUM
@module main
fn main() -> Int { 1 }
VELLUM",
         "error: no-main at 1:1\n"),
    Case("unknown-name", q"VELLUM
@module main
fn main() { x; }
VELLUM",
         "error: unknown-name at 1:13\n"),
    Case("arity", q"VELLUM
@module main
fn f(a: Int) {}
fn main() { f(); }
VELLUM",
         "error: arity at 2:13\n"),
    Case("not-callable", q"VELLUM
@module main
fn main() { let x = 1; x(); }
VELLUM",
         "error: not-callable at 1:24\n"),
    Case("not-struct", q"VELLUM
@module main
fn main() { let x = 1; x.a; }
VELLUM",
         "error: not-struct at 1:24\n"),
    Case("unknown-field", q"VELLUM
@module main
struct S { a: Int }
fn main() { let s = S.{ a: 1 }; s.b; }
VELLUM",
         "error: unknown-field at 2:35\n"),
    Case("dup-field", q"VELLUM
@module main
struct S { a: Int }
fn main() { let s = S.{ a: 1, a: 2 }; }
VELLUM",
         "error: dup-field at 2:31\n"),
    Case("not-indexable", q"VELLUM
@module main
fn main() { let x = 1; x[0]; }
VELLUM",
         "error: not-indexable at 1:24\n"),
    Case("no-method", q"VELLUM
@module main
fn main() { 1.foo(); }
VELLUM",
         "error: no-method at 1:15\n"),
    Case("not-ord", q"VELLUM
@module main
fn main() { let a = [1] < [2]; }
VELLUM",
         "error: not-ord at 1:21\n"),
    Case("not-eq-fn", q"VELLUM
@module main
fn main() { let f = || 1; f == f; }
VELLUM",
         "error: not-eq at 1:27\n"),
    Case("nonexh", q"VELLUM
@module main
fn main() { match 1 { 0 -> 1 } }
VELLUM",
         "error: type-mismatch at 1:28\n"),
    Case("unreach", q"VELLUM
@module main
fn main() { match true { _ -> 1, true -> 2 } }
VELLUM",
         "error: type-mismatch at 1:31\n"),
    Case("bad-value-ref", q"VELLUM
@module main
fn f() {}
fn main() { let x = f; }
VELLUM",
         "error: bad-value-ref at 2:21\n"),
    Case("bad-value-ref-ty", q"VELLUM
@module main
struct S {}
fn main() { let x = S; }
VELLUM",
         "error: bad-value-ref at 2:21\n"),
    Case("bad-pattern", q"VELLUM
@module main
fn main() { match 1.5 { 1.5 -> 1, _ -> 2 }; }
VELLUM",
         "error: bad-pattern at 1:25\n"),
    Case("refutable", q"VELLUM
@module main
fn main() { let Some(x) = Some(1); }
VELLUM",
         "error: refutable-pattern at 1:17\n"),
    Case("break-outside", q"VELLUM
@module main
fn main() { break; }
VELLUM",
         "error: break-outside at 1:13\n"),
    Case("assign-captured", q"VELLUM
@module main
fn main() { var x = 1; let f = || { x = 2; }; }
VELLUM",
         "error: assign-captured at 1:37\n"),
    Case("bad-target", q"VELLUM
@module main
fn main() { 1 = 2; }
VELLUM",
         "error: bad-target at 1:13\n"),
    Case("bad-target-str", q"VELLUM
@module main
fn main() { var s = "a"; s[0] = 'b'; }
VELLUM",
         "error: bad-target at 1:26\n"),
    Case("tuple9", q"VELLUM
@module main
fn main() { let t = (1,2,3,4,5,6,7,8,9); }
VELLUM",
         "error: bad-arity at 1:21\n"),
    Case("call17", q"VELLUM
@module main
fn f() {}
fn main() { f(1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17); }
VELLUM",
         "error: bad-arity at 2:13\n"),
    Case("cannot-infer-lambda", q"VELLUM
@module main
fn main() { let f = |x| x; }
VELLUM",
         "error: cannot-infer at 1:22\n"),
    Case("missing-return-lambda", q"VELLUM
@module main
fn main() { let f = |x: Int| -> Int { let y = 1; }; }
VELLUM",
         "error: missing-return at 1:21\n"),
    Case("not-iterable", q"VELLUM
@module main
fn main() { for x in 5 { } }
VELLUM",
         "error: not-iterable at 1:22\n"),
    Case("not-public", q"VELLUM
@module main
use o;
fn main() { o::f(); }@module o
fn f() {}

VELLUM",
         "error: bad-token at 2:22\n"),
    Case("unknown-module-path", q"VELLUM
@module main
fn main() { zz::f(); }
VELLUM",
         "error: unknown-module at 1:13\n"),
    Case("ambig", q"VELLUM
@module main
trait A { fn go(self); }
trait B { fn go(self); }
impl A for Int { fn go(self) {} }
impl B for Int { fn go(self) {} }
fn main() { 1.go(); }
VELLUM",
         "error: ambig-method at 5:15\n"),
    Case("unsat-method", q"VELLUM
@module main
trait A { fn go(self); }
fn main() { 1.go(); }
VELLUM",
         "error: unsatisfied-bound at 2:15\n"),
    Case("missing-field", q"VELLUM
@module main
struct S { a: Int }
fn main() { let s = S.{ }; }
VELLUM",
         "error: missing-field at 2:21\n"),
    Case("lex-bad", q"VELLUM
@module main
fn main() { $ }
VELLUM",
         "error: bad-token at 1:13\n"),
    Case("lex-unterm", q"VELLUM
@module main
fn main() { "abc }
VELLUM",
         "error: unterminated at 1:13\n"),
    Case("parse", q"VELLUM
@module main
fn main() { let = 1; }
VELLUM",
         "error: parse at 1:17\n"),
    Case("mismatch-let", q"VELLUM
@module main
fn main() { let x: Int = "s"; }
VELLUM",
         "error: type-mismatch at 1:26\n"),
    Case("assign-immut", q"VELLUM
@module main
fn f(a: Int) { a = 2; }
fn main() {}
VELLUM",
         "error: assign-immutable at 1:16\n"),
    Case("not-public-type", q"VELLUM
@module main
use o;
fn f(x: o::T) {}
fn main() { }
@module o
struct T {}

VELLUM",
         "error: not-public at 2:12\n"),
    Case("pub-ok", q"VELLUM
@module main
use o;
fn main() { print(o::f()); }
@module o
pub fn f() -> Str { "hi" }

VELLUM",
         "hi\n"),
    Case("trait-unknown-name", q"VELLUM
@module main
fn main() { Eq::go(1); }

VELLUM",
         "error: unknown-name at 1:17\n"),
    Case("enum-struct-lit", q"VELLUM
@module main
enum E { A }
fn main() { E.{ }; }

VELLUM",
         "error: not-struct at 2:13\n"),
    Case("let-pattern-type", q"VELLUM
@module main
fn main() { let (a, b) = 1; }

VELLUM",
         "error: type-mismatch at 1:17\n"),
    Case("for-range", q"VELLUM
@module main
fn main() { for i in 0 .. 3 { emit(showInt(i)); } print(""); }

VELLUM",
         "012\n"),
    Case("generic-infer-none", q"VELLUM
@module main
fn main() { let x = None; }

VELLUM",
         "error: cannot-infer at 1:21\n"),
    Case("let-annot", q"VELLUM
@module main
fn main() { let x: Option<Int> = None; print(showBool(isNone(x))); }

VELLUM",
         "true\n"),
    Case("missing-return", q"VELLUM
@module main
fn f() -> Int { let x = 1; }
fn main() { f(); }

VELLUM",
         "error: missing-return at 1:1\n"),
    Case("diverge-ok", q"VELLUM
@module main
fn f() -> Int { return 1; }
fn main() { print(showInt(f())); }

VELLUM",
         "1\n"),
    Case("wrong-unit-tail", q"VELLUM
@module main
fn f() { 5 }
fn main() { f(); }

VELLUM",
         "error: type-mismatch at 1:10\n"),
    Case("dup-pattern-name", q"VELLUM
@module main
fn main() { let (a, a) = (1, 2); }

VELLUM",
         "error: dup-name at 1:21\n"),
    Case("map-literal-order", q"VELLUM
@module main
fn main() { let m = #[1: "a", 1: "b"]; print(m[1]); print(showInt(mapLen(m))); }

VELLUM",
         "b\n1\n"),
    Case("string-iter", q"VELLUM
@module main
fn main() { for c in "héy" { emit(showInt(ord(c)) ++ ","); } print(""); }

VELLUM",
         "104,233,121,\n"),
    Case("int-min-neg", q"VELLUM
@module main
fn main() { print(showInt(-intMin())); print(showInt(intMin() % -1)); }

VELLUM",
         "-9223372036854775808\n0\n"),
    Case("shift-panic", q"VELLUM
@module main
fn main() { print(showInt(1 << 64)); }

VELLUM",
         "panic: shift amount out of range\n"),
    Case("hex-lit", q"VELLUM
@module main
fn main() { print(showInt(0xFF_FF + 0b1010 + 1_000)); }

VELLUM",
         "66545\n"),
    Case("float-lit", q"VELLUM
@module main
fn main() { print(showFloat(1e3 + 2.5e-1 + 1_0.5)); }

VELLUM",
         "1010.750000\n"),
    Case("char-escapes", q"VELLUM
@module main
fn main() { print(quoteStr("\u{7f}\u{1}a")); print(showChar('\u{e9}')); }

VELLUM",
         "\"\\u{7f}\\u{1}a\"\né\n"),
    Case("concat-list", q"VELLUM
@module main
fn main() { let a = [1]; let b = a ++ [2]; push(a, 9); print(showInt(listLen(b)) ++ showInt(listLen(a))); }

VELLUM",
         "22\n"),
    Case("closure-by-value", q"VELLUM
@module main
fn main() { var x = 1; let f = || x; x = 2; print(showInt(f())); }

VELLUM",
         "1\n"),
    Case("sort-stable", q"VELLUM
@module main
fn main() { let xs = [(1,"a"),(0,"b"),(1,"c"),(0,"d")]; let s = sortBy(xs, |p, q| cmpI(fst(p), fst(q))); for p in s { emit(snd(p)); } print(""); }

VELLUM",
         "bdac\n"),
    Case("fmt-bad", q"VELLUM
@module main
fn main() { print(fmt("{} {}", ["a"])); }

VELLUM",
         "panic: bad format\n"),
    Case("pow", q"VELLUM
@module main
fn main() { print(showInt(powI(2, 63)) ++ " " ++ showFloat(powF(2.0, -2))); }

VELLUM",
         "-9223372036854775808 0.250000\n"),
    Case("map-missing", q"VELLUM
@module main
fn main() { let m = #[1: 2]; print(showInt(m[5])); }

VELLUM",
         "panic: missing key\n"),
    Case("trait-impl-for-generic", q"VELLUM
@module main
trait T { fn f(self) -> Int; }
impl<A: T> T for Option<A> { fn f(self) -> Int { match self { Some(x) -> x.f() + 1, None -> 0 } } }
impl T for Int { fn f(self) -> Int { self } }
fn main() { print(showInt(Some(Some(5)).f())); }

VELLUM",
         "7\n"),
    Case("unsat-nested", q"VELLUM
@module main
trait T { fn f(self) -> Int; }
impl<A: T> T for Option<A> { fn f(self) -> Int { 0 } }
fn main() { print(showInt(Some(5).f())); }

VELLUM",
         "error: unsatisfied-bound at 3:35\n"),
    Case("infer-some", q"VELLUM
@module main
fn main() { let x = Some(1); print(showBool(isSome(x))); }

VELLUM",
         "true\n"),
    Case("infer-listnew", q"VELLUM
@module main
fn main() { let xs = listNew(); }

VELLUM",
         "error: cannot-infer at 1:22\n"),
    Case("infer-ok", q"VELLUM
@module main
fn main() { let r = Ok(1); }

VELLUM",
         "error: cannot-infer at 1:21\n"),
    Case("infer-if-none", q"VELLUM
@module main
fn main() { let c = true; let x = if c { None } else { Some(1) }; }

VELLUM",
         "error: cannot-infer at 1:42\n"),
    Case("check-if-none", q"VELLUM
@module main
fn f(c: Bool) -> Option<Int> { if c { None } else { Some(1) } }
fn main() { print(showBool(isNone(f(false)))); }

VELLUM",
         "false\n"),
    Case("listmap-empty", q"VELLUM
@module main
fn main() { let a: [Int] = listMap([], |x: Int| x); print(showInt(listLen(a))); }

VELLUM",
         "0\n"),
    Case("pass-empty", q"VELLUM
@module main
fn f(xs: [Int]) -> Int { listLen(xs) }
fn main() { print(showInt(f([]))); }

VELLUM",
         "0\n"),
    Case("nested-generic", q"VELLUM
@module main
fn main() { let m: #[Str: [Int]] = #["a": []]; print(showInt(listLen(m["a"]))); }

VELLUM",
         "0\n"),
    Case("lambda-ret-infer", q"VELLUM
@module main
fn main() { let f = |x: Int| x + 1; print(showInt(f(2))); }

VELLUM",
         "3\n"),
    Case("lambda-bad-arity", q"VELLUM
@module main
fn main() { let xs = listMap([1], |a, b| a); }

VELLUM",
         "error: type-mismatch at 1:35\n"),
    Case("lambda-ret-return", q"VELLUM
@module main
fn main() { let f = |x: Int| { return x; }; }

VELLUM",
         "error: cannot-infer at 1:32\n"),
    Case("lambda-ret-ann", q"VELLUM
@module main
fn main() { let f = |x: Int| -> Int { return x; }; print(showInt(f(2))); }

VELLUM",
         "2\n"),
    Case("map-key-float", q"VELLUM
@module main
fn main() { let m: #[Int: Int] = mapNew(); mapSet(m, 1, 2); print(showInt(m[1])); }

VELLUM",
         "2\n"),
    Case("mapnew-keybound", q"VELLUM
@module main
fn main() { let m: #[Float: Int] = mapNew(); }

VELLUM",
         "error: bad-key-type at 1:20\n"),
    Case("generic-eq-bound", q"VELLUM
@module main
fn eq<T: Eq>(a: T, b: T) -> Bool { a == b }
fn main() { print(showBool(eq(1, 1)) ++ showBool(eq([1], [2]))); }

VELLUM",
         "truefalse\n"),
    Case("generic-no-bound", q"VELLUM
@module main
fn eq<T>(a: T, b: T) -> Bool { a == b }
fn main() {}

VELLUM",
         "error: not-eq at 1:32\n"),
    Case("generic-ord", q"VELLUM
@module main
fn lt<T: Ord>(a: T, b: T) -> Bool { a < b }
fn main() { print(showBool(lt(1, 2))); }

VELLUM",
         "true\n"),
    Case("generic-unsat-ord", q"VELLUM
@module main
fn lt<T: Ord>(a: T, b: T) -> Bool { a < b }
fn main() { print(showBool(lt([1], [2]))); }

VELLUM",
         "error: unsatisfied-bound at 2:28\n"),
    Case("key-bound", q"VELLUM
@module main
fn f<K: Key>(k: K) -> #[K: Int] { #[k: 1] }
fn main() { print(showInt(f("a")["a"])); }

VELLUM",
         "1\n"),
    Case("method-on-param", q"VELLUM
@module main
trait T { fn f(self) -> Int; }
fn g<A: T>(a: A) -> Int { a.f() }
impl T for Int { fn f(self) -> Int { self } }
fn main() { print(showInt(g(4))); }

VELLUM",
         "4\n"),
    Case("method-param-no-bound", q"VELLUM
@module main
trait T { fn f(self) -> Int; }
fn g<A>(a: A) -> Int { a.f() }
fn main() {}

VELLUM",
         "error: unsatisfied-bound at 2:26\n"),
    Case("struct-generic-infer", q"VELLUM
@module main
struct B<T> { v: T }
fn main() { let b = B.{ v: 3 }; print(showInt(b.v)); let c: B<Str> = B.{ v: "x" }; print(c.v); }

VELLUM",
         "3\nx\n"),
    Case("struct-cannot-infer", q"VELLUM
@module main
struct B<T> { v: [T] }
fn main() { let b = B.{ v: [] }; }

VELLUM",
         "error: cannot-infer at 2:21\n"),
    Case("mismatch-struct", q"VELLUM
@module main
struct B<T> { v: T }
fn main() { let c: B<Str> = B.{ v: 1 }; }

VELLUM",
         "error: type-mismatch at 2:36\n"),
    Case("enum-generic", q"VELLUM
@module main
enum T<A> { L, N(A) }
fn main() { let x: T<Int> = N(3); match x { N(v) -> print(showInt(v)), L -> print("l") } }

VELLUM",
         "3\n"),
    Case("unit-returning-expr-stmt", q"VELLUM
@module main
fn main() { 1 + 2; print("ok"); }

VELLUM",
         "ok\n"),
    Case("if-no-else-type", q"VELLUM
@module main
fn main() { if true { 5 } }

VELLUM",
         "error: type-mismatch at 1:23\n"),
    Case("block-trailing-unit", q"VELLUM
@module main
fn f() -> Int { if true { return 1; } }
fn main() { f(); }

VELLUM",
         "error: type-mismatch at 1:17\n"),
    Case("apply", q"VELLUM
@module main
fn apply<A, B>(f: fn(A) -> B, x: A) -> B { f(x) }
fn main() { print(showInt(apply(|x: Int| x + 1, 2))); }

VELLUM",
         "3\n"),
    Case("apply-noann", q"VELLUM
@module main
fn apply<A, B>(f: fn(A) -> B, x: A) -> B { f(x) }
fn main() { print(showInt(apply(|x| x + 1, 2))); }

VELLUM",
         "error: cannot-infer at 2:34\n"),
    Case("struct-closure", q"VELLUM
@module main
struct S { f: fn(Int) -> Int }
fn main() { let s = S.{ f: |x| x * 2 }; print(showInt((s.f)(4))); }

VELLUM",
         "8\n"),
    Case("closure-in-list", q"VELLUM
@module main
fn main() { let fs: [fn(Int) -> Int] = [|x| x + 1, |x| x * 2]; var t = 0; for f in fs { t = t + f(10); } print(showInt(t)); }

VELLUM",
         "31\n"),
    Case("closure-map", q"VELLUM
@module main
fn main() { var m: #[Str: fn(Int) -> Int] = mapNew(); m["a"] = |x| x + 1; print(showInt(m["a"](1))); }

VELLUM",
         "2\n"),
    Case("curry", q"VELLUM
@module main
fn add(a: Int) -> fn(Int) -> Int { |b| a + b }
fn main() { print(showInt(add(1)(2))); }

VELLUM",
         "3\n"),
    Case("recursion-via-fn", q"VELLUM
@module main
fn fix(n: Int, f: fn(Int) -> Int) -> Int { if n == 0 { 0 } else { f(n) + fix(n - 1, f) } }
fn main() { print(showInt(fix(4, |x| x * x))); }

VELLUM",
         "30\n"),
    Case("tuple-field-patterns", q"VELLUM
@module main
struct P { a: Int, b: (Int, Str) }
fn main() { let P.{ a, b: (n, s) } = P.{ a: 1, b: (2, "z") }; print(showInt(a + n) ++ s); }

VELLUM",
         "3z\n"),
    Case("struct-pat-rest", q"VELLUM
@module main
struct P { a: Int, b: Int }
fn main() { match P.{ a: 1, b: 2 } { P.{ a, .. } -> print(showInt(a)) } }

VELLUM",
         "1\n"),
    Case("guard-fallthrough", q"VELLUM
@module main
fn f(n: Int) -> Str { match n { x when x > 5 -> "big", 5 -> "five", _ -> "small" } }
fn main() { print(f(9) ++ f(5) ++ f(1)); }

VELLUM",
         "bigfivesmall\n"),
    Case("nested-match-block", q"VELLUM
@module main
fn f(o: Option<Int>) -> Int { match o { Some(x) -> { if x > 3 { return 1; } 2 }, None -> 0 } }
fn main() { print(showInt(f(Some(5)) * 10 + f(Some(1)))); }

VELLUM",
         "12\n"),
    Case("var-shadow", q"VELLUM
@module main
fn main() { let x = 1; { let x = 2; print(showInt(x)); } print(showInt(x)); }

VELLUM",
         "error: parse at 1:24\n"),
    Case("loop-closure-capture", q"VELLUM
@module main
fn main() { var fs: [fn() -> Int] = listNew(); for i in 0 .. 3 { push(fs, || i); } for f in fs { emit(showInt(f())); } print(""); }

VELLUM",
         "012\n"),
    Case("map-with-struct-values", q"VELLUM
@module main
struct P { x: Int }
fn main() { var m: #[Int: P] = mapNew(); m[1] = P.{ x: 5 }; print(showInt(m[1].x)); }

VELLUM",
         "5\n"),
    Case("eq-struct", q"VELLUM
@module main
struct P { x: Int, y: [Int] }
fn main() { print(showBool(P.{ x: 1, y: [1] } == P.{ x: 1, y: [1] })); }

VELLUM",
         "true\n"),
    Case("eq-enum", q"VELLUM
@module main
enum E { A(Int), B }
fn main() { print(showBool(A(1) == A(1)) ++ showBool(A(1) == B) ++ showBool(B == B)); }

VELLUM",
         "truefalsetrue\n"),
    Case("string-compare", q"VELLUM
@module main
fn main() { print(showBool("abc" < "abd") ++ showBool("ab" < "abc") ++ showBool("b" < "abc")); }

VELLUM",
         "truetruefalse\n"),
    Case("char-compare", q"VELLUM
@module main
fn main() { print(showBool('a' < 'b') ++ showBool(true > false)); }

VELLUM",
         "truetrue\n"),
    Case("list-eq-nested", q"VELLUM
@module main
fn main() { print(showBool([[1],[2]] == [[1],[2]])); }

VELLUM",
         "true\n"),
    Case("map-in-list-eq", q"VELLUM
@module main
fn main() { print(showBool([#[1: 2]] == [#[1: 2]])); }

VELLUM",
         "true\n"),
    Case("for-append", q"VELLUM
@module main
fn main() { var xs = [1]; var n = 0; for x in xs { if n < 3 { push(xs, x); n = n + 1; } } print(showInt(listLen(xs))); }

VELLUM",
         "4\n"),
    Case("trait-static-path", q"VELLUM
@module main
trait T { fn f(self, o: Int) -> Int; }
impl T for Int { fn f(self, o: Int) -> Int { self + o } }
fn main() { print(showInt(T::f(1, 2))); }

VELLUM",
         "3\n"),
    Case("trait-path-arity0", q"VELLUM
@module main
trait T { fn f(self) -> Int; }
fn main() { T::f(); }

VELLUM",
         "error: arity at 2:16\n"),
    Case("generic-trait-self", q"VELLUM
@module main
trait Eqq { fn same(self, o: Self) -> Bool; }
impl Eqq for Int { fn same(self, o: Int) -> Bool { self == o } }
fn main() { print(showBool(1.same(1))); }

VELLUM",
         "true\n"),
    Case("big-shift", q"VELLUM
@module main
fn main() { print(showInt(-1 >> 63) ++ showInt(1 << 63)); }

VELLUM",
         "-1-9223372036854775808\n"),
    Case("float-div", q"VELLUM
@module main
fn main() { print(showFloat(1.0 / 0.0) ++ showFloat(-1.0 / 0.0) ++ showFloat(0.0 / 0.0)); }

VELLUM",
         "inf-infnan\n"),
    Case("neg-zero", q"VELLUM
@module main
fn main() { let z = 0.0; print(showFloat(-z)); }

VELLUM",
         "-0.000000\n"),
    Case("trailing-commas", q"VELLUM
@module main
struct P<A, B,> { a: A, b: B, }
enum E { X(Int, Str,), Y, }
trait T { fn f(self, a: Int,) -> Int; }
impl<Q, R,> T for P<Q, R,> { fn f(self, a: Int,) -> Int { a } }
fn g(x: (Int, Str,), h: fn(Int,) -> Int,) -> Int { h(fst(x),) }
fn main() {
    let p = P.{ a: "s", b: 2, };
    let t = (1, "a",);
    let l = [1, 2,];
    let m = #[1: 2,];
    print(showInt(p.f(3,) + g(t, |v,| v + 1,) + listLen(l) + mapLen(m)));
    match X(1, "z",) { X(a, b,) -> print(b), Y -> {}, }
}

VELLUM",
         "8\nz\n"),
    Case("empty-enum-match", q"VELLUM
@module main
enum E {}
fn f(e: E) -> Int { match e { _ -> 1 } }
fn main() {}

VELLUM",
         "error: unreachable at 2:31\n"),
    Case("empty-match", q"VELLUM
@module main
enum E {}
fn f(e: E) -> Int { match e { } }
fn main() {}

VELLUM",
         "error: non-exhaustive at 2:21\n"),
    Case("gen-shr", q"VELLUM
@module main
struct W<T> { v: T }
fn f(x: W<W<Int>>) -> Int { x.v.v }
fn main() { print(showInt(f(W.{ v: W.{ v: 3 } }))); }

VELLUM",
         "3\n"),
    Case("neg-pattern", q"VELLUM
@module main
fn f(n: Int) -> Int { match n { -1 -> 10, 0 -> 20, _ -> 30 } }
fn main() { print(showInt(f(-1) + f(0) + f(5))); }

VELLUM",
         "60\n"),
    Case("char-pattern", q"VELLUM
@module main
fn f(c: Char) -> Int { match c { 'a' -> 1, '\n' -> 2, _ -> 3 } }
fn main() { print(showInt(f('a') + f('\n') * 10 + f('z') * 100)); }

VELLUM",
         "321\n"),
    Case("bool-tuple-exh", q"VELLUM
@module main
fn f(a: Bool, b: Bool) -> Int { match (a, b) { (true, true) -> 1, (true, false) -> 2, (false, _) -> 3 } }
fn main() { print(showInt(f(true, false) + f(false, true))); }

VELLUM",
         "5\n"),
    Case("comment-nesting", q"VELLUM
@module main
/* a /* b */ c */ fn main() { // x
 print("ok"); }

VELLUM",
         "ok\n"),
    Case("lambda-in-args", q"VELLUM
@module main
fn main() { print(strJoin(listMap([1, 2], |x| showInt(x * 2)), "-")); }

VELLUM",
         "2-4\n"),
    Case("unit-eq", q"VELLUM
@module main
fn main() { print(showBool(print("a") == print("b"))); }

VELLUM",
         "a\nb\ntrue\n"),
    Case("while-in-lambda", q"VELLUM
@module main
fn main() { let f = |n: Int| { var s = 0; var i = 0; while i < n { i = i + 1; if i == 3 { continue; } s = s + i; } s }; print(showInt(f(5))); }

VELLUM",
         "12\n"),
    Case("fwd-generic", q"VELLUM
@module main
fn f(x: Box<Int>) -> Int { x.v }
fn main() { print(showInt(f(Box.{ v: 3 }))); }
struct Box<T> { v: T }
VELLUM",
         "3\n"),
    Case("fwd-xmod", q"VELLUM
@module main
use o;
fn f(x: o::Box<Int>) -> Int { x.v }
fn main() { print(showInt(f(o::Box.{ v: 3 }))); }
@module o
pub struct Box<T> { v: T }
VELLUM",
         "3\n"),
    Case("fwd-unknown", q"VELLUM
@module main
fn f(x: Box<Nope>) {}
fn main() {}
struct Box<T> { v: T }
VELLUM",
         "error: unknown-type at 1:13\n"),
    Case("eq-sibling", q"VELLUM
@module main
fn main() {
    let t: (Option<Int>, Option<fn() -> Int>) = (None, None);
    let y = t == t;
}
VELLUM",
         "error: not-eq at 3:13\n"),
    Case("eq-rec", q"VELLUM
@module main
struct N { next: Option<N>, v: Int }
fn main() { let n = N.{ next: None, v: 1 }; print(showBool(n == n)); }
VELLUM",
         "true\n"),
    Case("append", q"VELLUM
@module main
fn main() { var s = ""; for i in 0 .. 300000 { s = s ++ "xy"; } let t = s ++ "a"; let u = s ++ "b"; print(showInt(strLen(s)) ++ showChar(charAt(t, 600000)) ++ showChar(charAt(u, 600000))); }
VELLUM",
         "600000ab\n"),
];
