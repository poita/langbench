(ns langvm.vm-test
  "Run-time semantics: evaluation order, values, closures, panics."
  (:require [clojure.string :as str]
            [clojure.test :refer [deftest is testing are]]
            [langvm.test-util :refer [run run-main]]))

(deftest output-and-panics
  (is (= "a\nb\n" (run-main "print(\"a\"); print(\"b\");")))
  (is (= "abc" (run-main "emit(\"a\"); emit(\"b\"); emit(\"c\");")))
  (is (= "x\npanic: boom\n" (run-main "print(\"x\"); panic(\"boom\"); print(\"y\");")))
  (testing "the panic line continues an unterminated emit"
    (is (= "apanic: boom\n" (run-main "emit(\"a\"); panic(\"boom\");")))))

(deftest integer-semantics
  (is (= "-9223372036854775808\n"
         (run-main "print(showInt(intMax() + 1));")))
  (is (= "-3 -1 -4 1\n"
         (run-main "print(fmt(\"{} {} {} {}\", [showInt(-7 / 2), showInt(-7 % 2), showInt(divFloor(-7, 2)), showInt(modFloor(-7, 2))]));")))
  (is (= "-9223372036854775808 0\n"
         (run-main "print(showInt(intMin() / -1) ++ \" \" ++ showInt(intMin() % -1));")))
  (is (= "4611686018427387904 -4\n"
         (run-main "print(showInt(1 << 62) ++ \" \" ++ showInt(-16 >> 2));")))
  (testing "division and shift panics"
    (is (= "panic: divide by zero\n" (run-main "let z = 0; print(showInt(1 / z));")))
    (is (= "panic: modulo by zero\n" (run-main "let z = 0; print(showInt(1 % z));")))
    (is (= "panic: shift amount out of range\n" (run-main "let s = 64; print(showInt(1 << s));")))
    (is (= "panic: shift amount out of range\n" (run-main "let s = -1; print(showInt(1 >> s));")))))

(deftest float-semantics
  (is (= "inf -inf nan\n"
         (run-main "let z = 0.0; print(showFloat(1.0 / z) ++ \" \" ++ showFloat(-1.0 / z) ++ \" \" ++ showFloat(z / z));")))
  (is (= "false true\n"
         (run-main "let n = nanF(); print(showBool(n == n) ++ \" \" ++ showBool(-0.0 == 0.0));")))
  (is (= "false\n" (run-main "print(showBool(-0.0 < 0.0));"))))

(deftest evaluation-order
  (testing "operands, arguments and struct fields"
    (is (= "123\n"
           (run "@module main
fn t(s: Str) -> Int { emit(s); 1 }
fn main() { let x = t(\"1\") + t(\"2\") + t(\"3\"); print(\"\"); }")))
    (is (= "ba\n"
           (run "@module main
struct P { a: Int, b: Int }
fn t(s: Str) -> Int { emit(s); 1 }
fn main() { let p = P.{ b: t(\"b\"), a: t(\"a\") }; print(\"\"); }")))
    (testing "the callee of an indirect call is evaluated first"
      (is (= "ca\n"
             (run "@module main
fn t(s: Str) -> Int { emit(s); 1 }
fn pick(s: Str) -> fn(Int) -> Int { emit(s); |x: Int| x }
fn main() { let r = pick(\"c\")(t(\"a\")); print(\"\"); }"))))))

(deftest short-circuit
  (is (= "false\n"
         (run "@module main
fn boom() -> Bool { panic(\"no\"); return true; }
fn main() { print(showBool(false && boom())); }")))
  (is (= "true\n"
         (run "@module main
fn boom() -> Bool { panic(\"no\"); return true; }
fn main() { print(showBool(true || boom())); }"))))

(deftest closures
  (is (= "6\n"
         (run "@module main
fn counter(start: Int) -> fn(Int) -> Int {
    var base = start;
    let f = |d: Int| base + d;
    base = base + 100;
    f
}
fn main() { print(showInt(counter(1)(5))); }")) "capture is by value")
  (is (= "0 1 4 9\n"
         (run-main "var fs: [fn() -> Int] = listNew();
for i in 0 .. 4 { push(fs, || i * i); }
var out: [Str] = listNew();
for g in fs { push(out, showInt(g())); }
print(strJoin(out, \" \"));")) "each iteration binds a fresh variable")
  (is (= "3\n"
         (run-main "let shared = [1, 2]; let grow = || push(shared, 3); grow(); print(showInt(listLen(shared)));"))
      "lists are shared by reference")
  (is (= "15\n"
         (run-main "let a = 1; let f = |x: Int| { let g = |y: Int| a + x + y; g(10) + 3 }; print(showInt(f(1)));"))
      "nested capture"))

(deftest loops
  (is (= "0 1 2 \n" (run-main "for i in 0 .. 3 { emit(showInt(i) ++ \" \"); } print(\"\");")))
  (is (= "\n" (run-main "for i in 5 .. 5 { emit(\"x\"); } print(\"\");")))
  (is (= "abc\n" (run-main "for c in \"abc\" { emit(showChar(c)); } print(\"\");")))
  (testing "appending to the iterated list extends the loop"
    (is (= "3\n" (run-main "let xs = [1]; var n = 0; for x in xs { n = n + 1; if listLen(xs) < 3 { push(xs, x); } } print(showInt(n));"))))
  (testing "break and continue inside expressions leave the stack clean"
    (is (= "ok\n" (run-main "var i = 0; while true { i = i + 1; let v = 1 + if i > 3 { break; } else { 1 }; if v == 0 { continue; } } print(\"ok\");")))))

(deftest maps
  (is (= "pear=11 fig=0 apple=7 \n"
         (run-main "var c = #[\"pear\": 1]; c[\"apple\"] = 2; c[\"pear\"] = c[\"pear\"] + 10; c[\"fig\"] = 0;
mapDel(c, \"apple\"); c[\"apple\"] = 7;
for k in keysOf(c) { emit(fmt(\"{}={} \", [k, showInt(c[k])])); } print(\"\");")))
  (is (= "true\n" (run-main "print(showBool(#[1: 2, 3: 4] == #[3: 4, 1: 2]));")))
  (is (= "panic: missing key\n" (run-main "let m = #[1: 2]; print(showInt(m[5]));"))))

(deftest equality
  (is (= "true false\n"
         (run-main "print(showBool([1, 2] == [1, 2]) ++ \" \" ++ showBool((1, \"a\") == (1, \"b\")));")))
  (is (= "true\n"
         (run "@module main
enum T { A(Int, [Str]), B }
fn main() { print(showBool(A(1, [\"x\"]) == A(1, [\"x\"]) && A(1, []) != B)); }"))))

(deftest string-semantics
  (is (= "5 é 8\n"
         (run-main "let s = \"héllo\"; print(showInt(strLen(s)) ++ \" \" ++ showChar(charAt(s, 1)) ++ \" \" ++ showInt(strLen(\"\\u{1F600}abcdefg\"))); ")))
  (testing "scalar indexing past a supplementary character"
    (is (= "b 2\n" (run-main "let s = \"\\u{1F600}b\"; print(showChar(s[1]) ++ \" \" ++ showInt(strLen(s)));"))))
  (is (= "panic: index out of bounds\n" (run-main "let s = \"ab\"; print(showChar(s[2]));"))))

(deftest traits-and-dispatch
  (is (= "int:42\n?:\"hi\"\nlist:[1, 2, 3]\n[[\"a\"], [\"b\", \"c\"]]\n"
         (run "@module main
trait Render { fn render(self) -> Str; fn tag(self) -> Str { \"?\" } }
impl Render for Int { fn render(self) -> Str { showInt(self) } fn tag(self) -> Str { \"int\" } }
impl Render for Str { fn render(self) -> Str { quoteStr(self) } }
impl<T: Render> Render for [T] {
    fn render(self) -> Str { \"[\" ++ strJoin(listMap(self, |x| x.render()), \", \") ++ \"]\" }
    fn tag(self) -> Str { \"list\" }
}
fn show2<T: Render>(x: T) -> Str { x.tag() ++ \":\" ++ x.render() }
fn main() {
    print(show2(42)); print(show2(\"hi\")); print(show2([1, 2, 3]));
    print(Render::render([[\"a\"], [\"b\", \"c\"]]));
}"))))

(deftest call-depth
  (let [prog (fn [n] (str "@module main
fn f(n: Int) -> Int { if n == 0 { 0 } else { 1 + f(n - 1) } }
fn main() { print(showInt(f(" n "))); }"))]
    (is (= "19998\n" (run (prog 19998))))
    (is (= "panic: call stack overflow\n" (run (prog 20000))))))

(deftest sort-by-call-sequence
  (is (= "cmp(3,1) cmp(2,4) cmp(1,2) cmp(3,2) cmp(3,4) \n1 2 3 4\n"
         (run-main "var log: [Str] = listNew();
let r = sortBy([3, 1, 2, 4], |a, b| { push(log, fmt(\"cmp({},{})\", [showInt(a), showInt(b)])); cmpI(a, b) });
emit(strJoin(log, \" \") ++ \" \\n\");
print(strJoin(listMap(r, |x| showInt(x)), \" \"));"))
      "the bottom-up merge sort of SPEC 15.6 is reproduced exactly"))
