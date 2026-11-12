(ns langvm.diagnostics-test
  "One program per error kind.  A `§` marks the token where the diagnostic is
  expected; it is removed before the program is run."
  (:require [clojure.string :as str]
            [clojure.test :refer [deftest is testing]]
            [langvm.test-util :as u]))

(defn- expectation
  "[source expected-output-line] for a marked module stream."
  [kind marked]
  (let [lines (str/split marked #"\n" -1)
        at (first (keep-indexed (fn [i l] (when (str/includes? l "§") i)) lines))
        header (last (filter #(str/starts-with? (nth lines %) "@module") (range (inc at))))
        col (inc (str/index-of (nth lines at) "§"))
        src (str/replace marked "§" "")]
    [src (str "error: " kind " at " (- at header) ":" col)]))

(defn- expect-error
  "Assert that module `main` with `body` (a marked string) yields `kind`."
  [kind marked]
  (let [marked (if (str/starts-with? marked "@module") marked (str "@module main\n" marked))
        [src line] (expectation kind marked)]
    (is (= line (str/trim (u/run src))) (str kind ": " marked))))

(deftest type-errors
  (expect-error "type-mismatch" "fn main() { let x: Int = §\"s\"; }")
  (expect-error "type-mismatch" "fn main() {\n  let n = 1;\n  print(n + §\"x\");\n}")
  (expect-error "type-mismatch" "fn f() { §5 }\nfn main() {}")
  (expect-error "type-mismatch" "fn main() { let x: Int = if true { 1 } else { §\"no\" }; }")
  (expect-error "unknown-name" "fn main() { §foo(); }")
  (expect-error "arity" "fn f(a: Int) {}\nfn main() { §f(1, 2); }")
  (expect-error "not-callable" "fn main() { let x = 1; §x(2); }")
  (expect-error "cannot-infer" "fn main() { var xs = §[]; }")
  (expect-error "cannot-infer" "fn main() { let x = §None; }")
  (expect-error "cannot-infer" "fn main() { let f = |§x| x; }")
  (expect-error "bad-value-ref" "fn main() { let f = §print; }")
  (expect-error "bad-arity" "fn main() { let t = §(1, 2, 3, 4, 5, 6, 7, 8, 9); }"))

(deftest struct-errors
  (expect-error "not-struct" "fn main() { let x = 1; let y = §x.f; }")
  (expect-error "unknown-field" "struct S { a: Int }\nfn main() { let s = S.{ a: 1 }; let y = s.§b; }")
  (expect-error "missing-field" "struct S { a: Int }\nfn main() { let s = §S.{ }; }")
  (expect-error "dup-field" "struct S { a: Int }\nfn main() { let s = S.{ a: 1, §a: 2 }; }")
  (expect-error "unknown-field" "struct S { a: Int }\nfn main() { let s = S.{ a: 1, §z: 2 }; }")
  (expect-error "not-struct" "enum E { A }\nfn main() { let s = §E.{ }; }"))

(deftest operator-errors
  (expect-error "not-indexable" "fn main() { let y = §1[0]; }")
  (expect-error "not-iterable" "fn main() { for c in §1 { } }")
  (expect-error "not-eq" "fn main() { let f = |x: Int| x; let b = §f == f; }")
  (expect-error "not-ord" "fn main() { let b = §[1] < [2]; }")
  (expect-error "bad-key-type" "fn main() { let m = #[§1.5: 2]; }"))

(deftest control-flow-errors
  (expect-error "break-outside" "fn main() { §break; }")
  (expect-error "break-outside" "fn main() { while true { let f = || { §break; }; } }")
  (expect-error "assign-immutable" "fn main() { let x = 1; §x = 2; }")
  (expect-error "assign-immutable" "fn f(a: Int) { §a = 2; }\nfn main() {}")
  (expect-error "assign-captured" "fn main() { var x = 1; let f = || { §x = 2; }; }")
  (expect-error "bad-target" "fn main() { §1 = 2; }")
  (expect-error "bad-target" "fn main() { let s = \"ab\"; §s[0] = 'c'; }")
  (expect-error "missing-return" "§fn f() -> Int { let x = 1; }\nfn main() {}")
  (expect-error "type-mismatch" "fn f() { §return 1; }\nfn main() {}"))

(deftest pattern-errors
  (expect-error "non-exhaustive" "enum E { A, B }\nfn f(e: E) -> Int { §match e { A -> 1 } }\nfn main() {}")
  (expect-error "unreachable" "fn main() { match 3 { _ -> {}, §1 -> {} } }")
  (expect-error "non-exhaustive" "fn main() { §match 3 { 1 -> {} } }")
  (expect-error "bad-pattern" "fn main() { match 1.5 { §1.5 -> {}, _ -> {} } }")
  (expect-error "refutable-pattern" "fn main() { let §1 = 1; }")
  (expect-error "dup-name" "fn main() { let (a, §a) = (1, 2); }")
  (expect-error "arity" "fn main() { match Some(1) { §Some(a, b) -> {}, None -> {} } }"))

(deftest declaration-errors
  (expect-error "dup-name" "fn f(a: Int, §a: Int) {}\nfn main() {}")
  (expect-error "dup-name" "fn f() {}\nfn §f() {}\nfn main() {}")
  (expect-error "reserved-name" "struct §Int {}\nfn main() {}")
  (expect-error "unknown-type" "fn f(x: §Nope) {}\nfn main() {}")
  (expect-error "arity-type" "fn f(x: §Option) {}\nfn main() {}")
  (expect-error "bad-key-type" "fn f(x: §#[Float: Int]) {}\nfn main() {}")
  (expect-error "self-outside" "fn f(x: §Self) {}\nfn main() {}")
  (expect-error "self-outside" "fn main() { §self; }")
  (expect-error "unknown-module" "use §nope;\nfn main() {}")
  (expect-error "unknown-trait" "fn f<T: §Nope>(x: T) {}\nfn main() {}"))

(deftest trait-and-impl-errors
  (expect-error "builtin-trait-impl" "§impl Eq for Int {}\nfn main() {}")
  (expect-error "bad-impl-head" "trait T { fn m(self); }\nimpl T for §[Int] { fn m(self) {} }\nfn main() {}")
  (expect-error "unused-param" "trait T { fn m(self); }\nimpl<§A> T for Int { fn m(self) {} }\nfn main() {}")
  (expect-error "dup-impl" "trait T { fn m(self); }\nimpl T for Int { fn m(self) {} }\n§impl T for Int { fn m(self) {} }\nfn main() {}")
  (expect-error "missing-method" "trait T { fn m(self); }\n§impl T for Int { }\nfn main() {}")
  (expect-error "extra-method" "trait T { fn m(self); }\nimpl T for Int { fn m(self) {} fn §z(self) {} }\nfn main() {}")
  (expect-error "sig-mismatch" "trait T { fn m(self) -> Int; }\nimpl T for Int { fn §m(self) -> Str { \"\" } }\nfn main() {}")
  (expect-error "unsatisfied-bound" "trait T { fn m(self); }\nfn g<A: T>(a: A) {}\nfn main() { §g(1); }")
  (expect-error "no-method" "fn main() { 1.§foo(); }")
  (expect-error "ambig-method"
                (str "trait A { fn go(self) -> Int; }\ntrait B { fn go(self) -> Int; }\n"
                     "impl A for Int { fn go(self) -> Int { 1 } }\nimpl B for Int { fn go(self) -> Int { 2 } }\n"
                     "fn main() { 3.§go(); }")))

(deftest module-errors
  (expect-error "not-public" "@module main\nuse m;\nfn main() { m::§f(); }\n@module m\nfn f() {}")
  (expect-error "unknown-name" "@module main\nuse m;\nfn main() { m::§g(); }\n@module m\npub fn f() {}")
  (expect-error "unknown-module" "@module main\nfn main() { §zzz::f(); }")
  (expect-error "parse" "@module main\nfn main() {}\n@module other\nfn f( §{\n}")
  (is (= "error: no-main at 1:1" (str/trim (u/run "@module main\nfn helper() {}\n"))))
  (is (= "error: no-main at 1:1" (str/trim (u/run "@module main\nfn main(x: Int) {}\n"))))
  (is (= "error: bad-module at 1:1" (str/trim (u/run "fn main() {}\n"))))
  (is (= "error: dup-module at 3:1" (str/trim (u/run "@module main\nfn main() {}\n@module main\n")))))

(deftest pass-order
  (testing "lexing precedes parsing precedes checking"
    (is (= "error: bad-token at 1:3"
           (str/trim (u/run "@module main\nfn f( {\n@module b\nx $\n@module c\nlet x: Int = \"s\"\n"))))
    (is (= "error: parse at 1:7"
           (str/trim (u/run "@module main\nfn main() { let x: Int = \"s\"; }\n@module other\nfn f( {\n}\n"))))))
