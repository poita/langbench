(ns typeinfer.core-test
  (:require [clojure.string :as str]
            [clojure.test :refer [deftest is testing]]
            [typeinfer.core :as core]))

(defn- lines [src]
  (str/split-lines (core/infer-source src)))

(defn- ty
  "Type of a single bare expression, or the error line."
  [expr]
  (let [[l] (lines (str "(" expr ");;"))]
    (if (str/starts-with? l "- : ") (subs l 4) l)))

(deftest spec-examples-test
  (is (= ["id : 'a -> 'a"
          "compose : ('a -> 'b) -> ('c -> 'a) -> 'c -> 'b"
          "- : ('a -> 'b) -> ('c -> 'a) -> 'c -> 'b"
          "len : 'a list -> int"
          "- : int * bool * int"
          "error: unify"]
         (lines "let id = fun x -> x;;
                 let compose f g x = f (g x);;
                 compose;;
                 let rec len l = if null l then 0 else 1 + len (tl l);;
                 (id 1, id true, len [true]);;
                 fun f -> (f 1, f true);;")))
  (is (= ["succ : (('a -> 'b) -> 'c -> 'a) -> ('a -> 'b) -> 'c -> 'b"
          "add : ('a -> 'b -> 'c) -> ('a -> 'd -> 'b) -> 'a -> 'd -> 'c"
          "error: occurs"
          "error: unbound"
          "id : 'a -> 'a"
          "g : 'a -> 'a"
          "- : int * bool"
          "- : ('a * 'b -> 'b * 'a) list"]
         (lines "let succ n = fun f x -> f (n f x);;
                 let add m n = fun f x -> m f (n f x);;
                 fun x -> x x;;
                 let g = id id;;
                 let id = fun x -> x;;
                 let g = id id;;
                 (g 1, g true);;
                 [fun p -> (snd p, fst p)];;")))
  (is (= ["map : int"
          "- : int"
          "- : 'a -> 'b -> 'c -> ('c -> 'c list) * ('a * 'b) * 'a"
          "error: unify"
          "error: unify"]
         (lines "let map = 3;;
                 map;;
                 fun a b c -> let p = (a, b) in (fun x -> [x; c], p, fst p);;
                 let rec bad x = bad 1 + bad true;;
                 1 :: [true];;"))))

(deftest empty-program-test
  (is (= "" (core/infer-source "")))
  (is (= "" (core/infer-source " \n "))))

(deftest literals-and-operators-test
  (is (= "int" (ty "12345678901234567890123")))
  (is (= "bool" (ty "true")))
  (is (= "unit" (ty "()")))
  (is (= "'a list" (ty "[]")))
  (is (= "int" (ty "1 + 2 * 3 - 4 / 5")))
  (is (= "bool" (ty "1 <= 2")))
  (is (= "bool" (ty "1 < 2 && 3 >= 2 || false")))
  (is (= "error: unify" (ty "true = false")))
  (is (= "int * int * int" (ty "(1, 2, 3)")))
  (is (= "error: unify" (ty "if true then (1, 2) else ((1, 2), 3)")))
  (is (= "int list" (ty "1 :: 2 :: []"))))

(deftest builtins-test
  (is (= "'a * 'b -> 'a" (ty "fst")))
  (is (= "('a -> 'b) -> 'a list -> 'b list" (ty "map")))
  (is (= "('a -> 'b -> 'a) -> 'a -> 'b list -> 'a" (ty "fold")))
  (is (= "'a list -> int" (ty "length")))
  (is (= "bool -> bool" (ty "not")))
  (is (= "int list" (ty "map (fun x -> x + 1) [1; 2]")))
  (is (= "int list -> int" (ty "fold (fun a b -> a + b) 0"))))

(deftest polymorphism-test
  (testing "let-bound variables are generalised, even for applications"
    (is (= "int * bool" (ty "let id = fun x -> x in let g = id id in (g 1, g true)"))))
  (testing "lambda-bound variables are monomorphic"
    (is (= "error: unify" (ty "fun f -> (f 1, f true)"))))
  (testing "a non-recursive let does not see its own name"
    (is (= "error: unbound" (ty "let x = x + 1 in x")))
    (is (= "int" (ty "let x = 1 in let x = x + 1 in x"))))
  (testing "recursive functions are monomorphic in their own body"
    (is (= "error: unify" (ty "let rec f x = f 1 + f true in f")))
    (is (= "'a -> 'b" (ty "let rec f x = f x in f"))))
  (testing "generalisation respects the environment"
    (is (= "'a -> 'a * 'a" (ty "fun x -> let y = x in (y, y)")))
    (is (= "error: unify" (ty "fun x -> let y = x in (y 1, y true)")))))

(deftest error-kinds-test
  (is (= "error: occurs" (ty "fun x -> x x")))
  (is (= "error: unbound" (ty "nope")))
  (is (= "error: unify" (ty "1 true")))
  (testing "the first problem met wins"
    (is (= "error: occurs" (ty "fun x -> if true then (x, 0) else ([x], true)")))
    (is (= "error: unify" (ty "true + undefined")))
    (is (= "error: unbound" (ty "undefined + true")))
    (is (= "error: occurs" (ty "fun x -> [(x, 0); ([x], true)]")))))

(deftest error-continuation-test
  (testing "a failing declaration adds nothing; later ones still run"
    (is (= ["error: unify" "error: unbound" "x : int" "- : int"]
           (lines "let x = 1 + true;; x;; let x = 1;; x;;"))))
  (testing "a failing redefinition keeps the earlier binding"
    (is (= ["x : int" "error: unify" "- : int"]
           (lines "let x = 1;; let x = x true;; x;;")))))

(deftest shadowing-builtins-test
  (is (= ["map : int" "- : int"] (lines "let map = 3;; map;;")))
  (is (= "'a -> 'a" (ty "let fst x = x in fst"))))

(deftest naming-test
  (testing "variables are renamed per declaration by first appearance"
    (is (= "'a -> 'b -> 'b" (ty "fun a b -> b")))
    (is (= "'a -> 'b -> 'a" (ty "fun a b -> a"))))
  (testing "after 'z comes 'a1"
    (let [params (str/join " " (map #(str "p" %) (range 30)))
          out (ty (str "fun " params " -> p29"))]
      (is (str/ends-with? out "-> 'd1"))
      (is (str/starts-with? out "'a -> 'b ")))))

(deftest deep-input-test
  (testing "deeply nested programs run inside with-deep-stack"
    (let [n 3000
          src (str (str/join (repeat n "(") ) "1" (str/join (repeat n ")")) ";;")]
      (is (= ["- : int"] (str/split-lines (core/with-deep-stack #(core/infer-source src)))))))
  (testing "long list and application chains"
    (is (= ["- : int list"]
           (str/split-lines
            (core/with-deep-stack
              #(core/infer-source (str "[" (str/join "; " (repeat 100000 "1")) "];;"))))))))

(deftest library-api-test
  (testing "infer-program yields result maps"
    (is (= [{:name "id" :type "'a -> 'a"}
            {:name nil :type "int"}
            {:error :unbound}]
           (vec (core/infer-program "let id x = x;; id 1;; y;;")))))
  (testing "format-result"
    (is (= "id : 'a -> 'a" (core/format-result {:name "id" :type "'a -> 'a"})))
    (is (= "- : int" (core/format-result {:name nil :type "int"})))
    (is (= "error: occurs" (core/format-result {:error :occurs}))))
  (testing "the environment can be threaded explicitly"
    (let [[d1 d2] (typeinfer.parser/parse-program "let k x y = x;; k 1;;")
          [env r1] (core/infer-decl (core/initial-env) d1)
          [_ r2] (core/infer-decl env d2)]
      (is (= "'a -> 'b -> 'a" (:type r1)))
      (is (= "'a -> int" (:type r2)))))
  (testing "syntax errors surface lazily"
    (let [rs (core/infer-program "1;; let = ;;")]
      (is (= {:name nil :type "int"} (first rs)))
      (is (thrown? clojure.lang.ExceptionInfo (doall rs))))))
