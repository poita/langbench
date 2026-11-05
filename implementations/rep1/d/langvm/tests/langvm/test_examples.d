/// End-to-end tests: the worked examples of the language specification (section 17).
module langvm.test_examples;

import core.exception : AssertError;
import langvm;

private void check(string name, string input, string expected, string file = __FILE__, size_t line = __LINE__)
{
    auto got = runSource(input).stdout;
    if (got != expected)
        throw new AssertError("example " ~ name ~ ":\nexpected:\n" ~ expected ~ "\ngot:\n" ~ got, file, line);
}

unittest
{
    check("1", q"EOS
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
EOS", q"EOS
hello, Vellum!
hello, world!
EOS");
}

unittest
{
    check("2", q"EOS
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
EOS", q"EOS
3628800
3 5 7 3 11 
14
EOS");
}

unittest
{
    check("3", q"EOS
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
EOS", q"EOS
seven 7
found y=20
true
7/seven
EOS");
}

unittest
{
    check("4", q"EOS
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
EOS", q"EOS
circle....................... 12
circle....................... 0
rect......................... 12
square....................... 25
nothing...................... 0
group starting with a circle. 7
EOS");
}

unittest
{
    check("5", q"EOS
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
EOS", q"EOS
int:42
?:"hi"
list:[1, 2, 3]
?:3x4
[["a"], ["b", "c"]]
EOS");
}

unittest
{
    check("6", q"EOS
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
EOS", q"EOS
6
14
1,3,5,8
17
3
EOS");
}

unittest
{
    check("7", q"EOS
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
EOS", q"EOS
pear=11 fig=0 apple=7 
3
false
-1
true
1x 2y 
EOS");
}

unittest
{
    check("8", q"EOS
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
EOS", q"EOS
-9223372036854775808
9223372036854775807
-3 -1
-4 1
-3 1
-9223372036854775808
ff -11111111
4611686018427387904 -4
12 7 -1
3486784401 12
8 63 3
true
-42
EOS");
}

unittest
{
    check("9", q"EOS
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
EOS", q"EOS
1.000000
0.666667
-0.000000
2 4 0
0.30000000000000004
0.3333333333
1.414214
3.141593
nan inf -inf
4607182418800017408
1024.000000 0.250000
-3 -3.000000 -3.000000
false 1
9007199254740992.000000
EOS");
}

unittest
{
    check("10", q"EOS
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
EOS", q"EOS
12
éö
wörld
HéLLO, WöRLD
a||b|
ba
[007] [x--]
"tab\there\n"
2 10 -1
cba pad!
Vel
-101
true '\''
EOS");
}

unittest
{
    check("11", q"EOS
@module main
fn get(xs: [Int], i: Int) -> Int { xs[i] }

fn main() {
    let xs = [10, 20, 30];
    print(showInt(get(xs, 2)));
    print(showInt(get(xs, 3)));
    print("never reached");
}
EOS", q"EOS
30
panic: index out of bounds
EOS");
}

unittest
{
    check("12", q"EOS
@module main
fn main() {
    let n: Int = 1;
    print(n + "x");
}
EOS", q"EOS
error: type-mismatch at 3:15
EOS");
}

unittest
{
    check("13", q"EOS
@module main
enum Colour { Red, Green, Blue }

fn name(c: Colour) -> Str {
    match c {
        Red -> "red",
        Green -> "green",
    }
}

fn main() { print(name(Blue)); }
EOS", q"EOS
error: non-exhaustive at 4:5
EOS");
}

unittest
{
    check("14", q"EOS
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
EOS", q"EOS
error: unsatisfied-bound at 12:19
EOS");
}

unittest
{
    check("15", q"EOS
@module main
fn main() {
    let x: Int = "s";
}
@module other
fn f( {
}
EOS", q"EOS
error: parse at 1:7
EOS");
}

unittest
{
    check("16", q"EOS
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
EOS", q"EOS
3 4 + => 7
x y - => 6
2 3 4 * + => 14
x 0 / => error: divide by zero
z 1 + => error: unbound z
1 2 => error: leftover
5 1 2 + 4 * + 3 - => 14
EOS");
}

unittest
{
    check("17.0", q"EOS
@module main
fn main() {
    let x = 1;
    x = 2;
}
EOS", "error: assign-immutable at 3:5\n");
}

unittest
{
    check("17.1", q"EOS
@module main
fn main() {
    var xs = [];
}
EOS", "error: cannot-infer at 2:14\n");
}

unittest
{
    check("17.2", q"EOS
@module main
fn main() {
    match 3 {
        _ -> print("a"),
        1 -> print("b"),
    }
}
EOS", "error: unreachable at 4:9\n");
}

unittest
{
    check("17.3", q"EOS
@module main
trait A { fn go(self) -> Int; }
trait B { fn go(self) -> Int; }

impl A for Int { fn go(self) -> Int { 1 } }
impl B for Int { fn go(self) -> Int { 2 } }

fn main() {
    print(showInt(3.go()));
}
EOS", "error: ambig-method at 8:21\n");
}

unittest
{
    check("17.4", q"EOS
@module main
fn main() {
    print(showInt(len([1, 2])));
}
EOS", "error: unknown-name at 2:19\n");
}

unittest
{
    check("17.5", q"EOS
@module main
fn f() -> Int {
    let x = 1;
}

fn main() { print(showInt(f())); }
EOS", "error: missing-return at 1:1\n");
}

unittest
{
    check("17.6", q"EOS
@module main
struct S { a: Int, b: Int }

fn main() {
    let s = S.{ a: 1 };
    print(showInt(s.a));
}
EOS", "error: missing-field at 4:13\n");
}

unittest
{
    check("17.7", q"EOS
@module main
fn main() {
    let t = (1, "two");
    print(showBool(t == (1, "two")));
    let f = |x: Int| x;
    print(showBool(f == f));
}
EOS", "error: not-eq at 5:20\n");
}

unittest
{
    check("17.8", q"EOS
@module main
fn main() {
    for c in 'a' { print(showChar(c)); }
}
EOS", "error: not-iterable at 2:14\n");
}

unittest
{
    check("17.9", q"EOS
@module main
fn main() {
    let m = #[1.5: "x"];
}
EOS", "error: bad-key-type at 2:15\n");
}
