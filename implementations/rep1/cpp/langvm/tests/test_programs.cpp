// End-to-end behaviour of whole Vellum programs.
#include <gtest/gtest.h>

#include "support.h"

using testsupport::runMain;
using testsupport::runStream;

TEST(Programs, HelloWorldAcrossModules) {
  EXPECT_EQ(runStream("@module main\nuse util;\nfn main() { print(util::greet(\"world\")); }\n"
                      "@module util\npub fn greet(who: Str) -> Str { \"hello, \" ++ who }\n"),
            "hello, world\n");
}

TEST(Programs, IntegerArithmeticWrapsAndTruncates) {
  EXPECT_EQ(runMain(R"(fn main() {
    print(showInt(intMax() + 1));
    print(showInt(-7 / 2) ++ " " ++ showInt(-7 % 2));
    print(showInt(intMin() / -1));
    print(showInt(-16 >> 2) ++ " " ++ showInt(1 << 62));
})"),
            "-9223372036854775808\n-3 -1\n-9223372036854775808\n-4 4611686018427387904\n");
}

TEST(Programs, PanicAppendsToUnterminatedOutput) {
  EXPECT_EQ(runMain("fn main() { emit(\"a\"); panic(\"boom\"); print(\"x\"); }\n"), "apanic: boom\n");
}

TEST(Programs, RuntimePanicMessages) {
  EXPECT_EQ(runMain("fn main() { let xs = [1]; print(showInt(xs[1])); }\n"), "panic: index out of bounds\n");
  EXPECT_EQ(runMain("fn main() { print(showInt(1 / (1 - 1))); }\n"), "panic: divide by zero\n");
  EXPECT_EQ(runMain("fn main() { print(showInt(1 % (1 - 1))); }\n"), "panic: modulo by zero\n");
  EXPECT_EQ(runMain("fn main() { print(showInt(1 << 64)); }\n"), "panic: shift amount out of range\n");
  EXPECT_EQ(runMain("fn main() { let m = #[1: 2]; print(showInt(m[3])); }\n"), "panic: missing key\n");
}

TEST(Programs, CallDepthLimitIs20000Frames) {
  const char* body = R"(fn down(n: Int) -> Int { if n == 0 { 0 } else { 1 + down(n - 1) } }
fn main() { print(showInt(down(19998))); print(showInt(down(19999))); })";
  EXPECT_EQ(runMain(body), "19998\npanic: call stack overflow\n");
}

TEST(Programs, ClosuresCaptureByValue) {
  EXPECT_EQ(runMain(R"(fn counter(start: Int) -> fn(Int) -> Int {
    var base = start;
    let f = |d: Int| base + d;
    base = base + 100;
    f
}
fn main() {
    print(showInt(counter(1)(5)));
    var fs: [fn() -> Int] = listNew();
    for i in 0 .. 4 { push(fs, || i * i); }
    var acc = 0;
    for g in fs { acc = acc + g(); }
    print(showInt(acc));
})"),
            "6\n14\n");
}

TEST(Programs, StructsEnumsAndPatterns) {
  EXPECT_EQ(runMain(R"(enum Shape { Circle(Int), Rect(Int, Int), Group([Shape]), Empty }
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
fn main() {
    print(showInt(area(Group([Circle(1), Rect(2, 2), Circle(-1)]))));
})"),
            "7\n");
}

TEST(Programs, StructLiteralEvaluatesInWrittenOrder) {
  EXPECT_EQ(runMain(R"(struct P { a: Int, b: Int }
fn t(s: Str, v: Int) -> Int { emit(s); v }
fn main() {
    let p = P.{ b: t("b", 2), a: t("a", 1) };
    print(" " ++ showInt(p.a) ++ showInt(p.b));
})"),
            "ba 12\n");
}

TEST(Programs, TraitsDefaultsAndBounds) {
  EXPECT_EQ(runMain(R"(trait Render {
    fn render(self) -> Str;
    fn tag(self) -> Str { "?" }
}
impl Render for Int { fn render(self) -> Str { showInt(self) } fn tag(self) -> Str { "int" } }
impl Render for Str { fn render(self) -> Str { quoteStr(self) } }
impl<T: Render> Render for [T] {
    fn render(self) -> Str { "[" ++ strJoin(listMap(self, |x| x.render()), ", ") ++ "]" }
    fn tag(self) -> Str { "list" }
}
fn show2<T: Render>(x: T) -> Str { fmt("{}:{}", [x.tag(), x.render()]) }
fn main() {
    print(show2(42));
    print(show2("hi"));
    print(show2([1, 2]));
    print(Render::render([["a"], ["b", "c"]]));
})"),
            "int:42\n?:\"hi\"\nlist:[1, 2]\n[[\"a\"], [\"b\", \"c\"]]\n");
}

TEST(Programs, MapsKeepInsertionOrder) {
  EXPECT_EQ(runMain(R"(fn main() {
    var m = #["pear": 1];
    m["apple"] = 2;
    m["pear"] = m["pear"] + 10;
    mapDel(m, "apple");
    m["apple"] = 7;
    for k in keysOf(m) { emit(k ++ "=" ++ showInt(m[k]) ++ " "); }
    print("");
    print(showBool(#[1: 2, 3: 4] == #[3: 4, 1: 2]));
})"),
            "pear=11 apple=7 \ntrue\n");
}

TEST(Programs, ForLoopSeesAppendsToTheIteratedList) {
  EXPECT_EQ(runMain(R"(fn main() {
    let xs = [1, 2];
    var n = 0;
    for x in xs { n = n + 1; if x < 3 { push(xs, x + 2); } }
    print(showInt(n));
})"),
            "4\n");
}

TEST(Programs, BreakInsideExpressionContextRestoresStack) {
  EXPECT_EQ(runMain(R"(fn id(a: Int, b: Int) -> Int { a + b }
fn main() {
    var n = 0;
    while true {
        n = n + 1;
        let v = id(10, match n { 3 -> { break; }, _ -> n });
        emit(showInt(v) ++ " ");
    }
    print("done " ++ showInt(n));
})"),
            "11 12 done 3\n");
}

TEST(Programs, ShadowedPreludeNamesAreAllowed) {
  EXPECT_EQ(runMain(R"(enum Option<T> { Nothing, Just(T) }
fn print2(x: Int) { print(showInt(x)); }
fn main() {
    let o: Option<Int> = Just(3);
    match o { Nothing -> print("none"), Just(v) -> print2(v) }
    print(showBool(isSome(Some(1))));
})"),
            "3\ntrue\n");
}

TEST(Programs, DeepStructuresDoNotOverflowTheHostStack) {
  EXPECT_EQ(runMain(R"(enum L { Nil, Cons(Int, L) }
fn main() {
    var l = Nil;
    for i in 0 .. 300000 { l = Cons(i, l); }
    print("built");
})"),
            "built\n");
}
