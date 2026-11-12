(ns typeinfer.parser-test
  (:require [clojure.test :refer [deftest is testing]]
            [typeinfer.parser :as parser]))

(defn- expr [src]
  (:expr (first (parser/parse-program (str "(" src ");;")))))

(defn- v [n] {:op :var :name n})
(defn- bin [op l r] {:op :binop :operator op :left l :right r})

(deftest program-structure-test
  (is (= [] (parser/parse-program "")))
  (is (= [] (parser/parse-program " \n\t")))
  (is (= [{:kind :let :name "x" :expr {:op :int}}
          {:kind :expr :expr (v "x")}]
         (parser/parse-program "let x = 1;; x;;")))
  (is (= [{:kind :letrec :name "f"
           :expr {:op :fun :params ["x"] :body (v "x")}}]
         (parser/parse-program "let rec f x = x;;"))))

(deftest sugar-test
  (is (= {:op :fun :params ["x" "y"] :body (v "x")}
         (:expr (first (parser/parse-program "let f x y = x;;")))))
  (is (= {:op :let :name "f" :rhs {:op :fun :params ["a"] :body (v "a")} :body (v "f")}
         (expr "let f a = a in f"))))

(deftest precedence-test
  (testing "application binds tighter than * and +"
    (is (= (bin "+" {:op :app :fn (v "f") :arg (v "x")}
                (bin "*" {:op :app :fn (v "g") :arg (v "y")} {:op :int}))
           (expr "f x + g y * 2"))))
  (testing "left associativity"
    (is (= (bin "-" (bin "-" (v "a") (v "b")) (v "c")) (expr "a - b - c"))))
  (testing ":: is right associative and looser than +"
    (is (= {:op :cons :head {:op :int}
            :tail {:op :cons :head {:op :app :fn (v "f") :arg (v "x")} :tail (v "l")}}
           (expr "1 :: f x :: l")))
    (is (= {:op :cons :head (bin "+" (v "a") (v "b")) :tail (v "l")} (expr "a + b :: l"))))
  (testing "comparison is looser than ::, && looser than comparison"
    (is (= (bin "&&" (bin "<" (v "a") (v "b")) (v "c")) (expr "a < b && c")))
    (is (= (bin "||" (bin "&&" (v "a") (v "b")) (v "c")) (expr "a && b || c"))))
  (testing "application is left-associative, arguments are atoms"
    (is (= {:op :app :fn {:op :app :fn (v "f") :arg (v "x")} :arg (v "y")}
           (expr "f x y")))))

(deftest binders-extend-right-test
  (is (= {:op :fun :params ["x"] :body (bin "+" (v "x") {:op :int})} (expr "fun x -> x + 1")))
  (is (= (bin "+" (v "c") {:op :int})
         (:else (expr "if a then b else c + 1"))))
  (testing "bodies stop at , ; ) ]"
    (is (= {:op :tuple :elems [{:op :fun :params ["x"] :body (v "x")} {:op :int}]}
           (expr "(fun x -> x, 1)")))
    (is (= {:op :list :elems [{:op :fun :params ["x"] :body (v "x")}
                              {:op :fun :params ["y"] :body {:op :int}}]}
           (expr "[fun x -> x; fun y -> 1]")))
    (is (= {:op :tuple :elems [{:op :let :name "y" :rhs {:op :int} :body (v "y")} {:op :int}]}
           (expr "(let y = 1 in y, 2)")))))

(deftest atoms-test
  (is (= {:op :unit} (expr "()")))
  (is (= {:op :nil} (expr "[]")))
  (is (= {:op :bool :value false} (expr "false")))
  (is (= (v "x") (expr "((x))")))
  (is (= 3 (count (:elems (expr "(1, 2, 3)")))))
  (is (= {:op :tuple :elems [{:op :tuple :elems [{:op :int} {:op :int}]} {:op :int}]}
         (expr "((1, 2), 3)"))))

(deftest let-declaration-vs-expression-test
  (is (= :let (:kind (first (parser/parse-program "let x = 1;;")))))
  (is (= :expr (:kind (first (parser/parse-program "(let x = 1 in x);;"))))))

(deftest syntax-errors-test
  (doseq [bad ["let x = ;;" "1 +;;" "(1, ;;" "let rec x = 1;;" "fun -> x;;" "1"]]
    (is (thrown? clojure.lang.ExceptionInfo (parser/parse-program bad)) bad))
  (testing "earlier declarations are available lazily"
    (is (= {:kind :let :name "a" :expr {:op :int}}
           (first (parser/parse-decls "let a = 1;; let b = ;;"))))))
