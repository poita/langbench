(ns langvm.patterns-test
  "Exhaustiveness, reachability and irrefutability (SPEC section 12)."
  (:require [clojure.string :as str]
            [clojure.test :refer [deftest is testing]]
            [langvm.test-util :refer [run]]))

(def ^:private decls
  "enum Tri { A, B, C(Int) }
   struct Pair { a: Int, b: Bool }
   enum Void { }")

(defn- verdict
  "What the checker says about a `match` over the given scrutinee type: `ok`,
  or the diagnostic kind."
  [scrut-type arms]
  (let [out (run (str "@module main\n" decls "\n"
                      "fn f(v: " scrut-type ") -> Int { match v { " arms " } }\n"
                      "fn main() {}\n"))]
    (if-let [[_ kind] (re-find #"^error: (\S+)" out)] kind "ok")))

(deftest enum-matches
  (is (= "ok" (verdict "Tri" "A -> 1, B -> 2, C(n) -> n")))
  (is (= "non-exhaustive" (verdict "Tri" "A -> 1, C(_) -> 2")))
  (is (= "ok" (verdict "Tri" "A -> 1, B -> 2, C(0) -> 3, C(_) -> 4")))
  (is (= "unreachable" (verdict "Tri" "_ -> 0, A -> 1")))
  (is (= "ok" (verdict "Tri" "A when true -> 1, A -> 2, B -> 3, C(_) -> 4")))
  (is (= "non-exhaustive" (verdict "Tri" "A when true -> 1, B -> 3, C(_) -> 4"))))

(deftest literals
  (is (= "non-exhaustive" (verdict "Int" "0 -> 1, 1 -> 2")))
  (is (= "ok" (verdict "Int" "0 -> 1, n -> n")))
  (is (= "ok" (verdict "Bool" "true -> 1, false -> 0")))
  (is (= "non-exhaustive" (verdict "Bool" "true -> 1")))
  (is (= "unreachable" (verdict "Int" "1 -> 1, 1 -> 2, _ -> 3")))
  (is (= "ok" (verdict "Str" "\"a\" -> 1, _ -> 2"))))

(deftest lists
  (is (= "ok" (verdict "[Int]" "[] -> 0, [a] -> a, [a, b, ..] -> a + b")))
  (is (= "unreachable" (verdict "[Int]" "[] -> 0, [_, ..] -> 1, [..] -> 2")))
  (is (= "non-exhaustive" (verdict "[Int]" "[] -> 0, [a, b] -> a")))
  (is (= "ok" (verdict "[Int]" "[a, ..rest] -> a, [] -> 0")))
  (is (= "unreachable" (verdict "[Int]" "[..] -> 0, [1] -> 1"))))

(deftest structs-tuples-and-void
  (is (= "non-exhaustive" (verdict "Pair" "Pair.{ a: 1, b: _ } -> 1")))
  (is (= "ok" (verdict "Pair" "Pair.{ a: 1, .. } -> 1, Pair.{ b, .. } -> 2")))
  (is (= "ok" (verdict "(Bool, Bool)" "(true, _) -> 1, (_, true) -> 2, (false, false) -> 3")))
  (is (= "unreachable" (verdict "Void" "_ -> 0")))
  (is (= "non-exhaustive" (verdict "Void" ""))))

(deftest irrefutable-patterns
  (let [ok? (fn [body] (not (str/starts-with? (run (str "@module main\n" decls "\nfn main() { " body " }\n")) "error")))]
    (is (ok? "let (a, b) = (1, 2);"))
    (is (ok? "let Pair.{ a, b } = Pair.{ a: 1, b: true };"))
    (is (ok? "let [..] = [1];"))
    (is (ok? "let [..rest] = [1];"))
    (is (not (ok? "let [a] = [1];")))
    (is (not (ok? "let Some(x) = Some(1);")))
    (is (not (ok? "let true = true;")))
    (is (not (ok? "for Some(x) in [Some(1)] { }")))))
