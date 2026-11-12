(ns langvm.parser-test
  (:require [clojure.test :refer [deftest is testing are]]
            [langvm.diag :as diag]
            [langvm.lexer :as lexer]
            [langvm.parser :as parser]))

(defn- parse [src] (parser/parse-module (lexer/lex [src])))

(defn- parse-error [src]
  (try (parse src) nil
       (catch clojure.lang.ExceptionInfo e (diag/format-diag e))))

(defn- body-of [src]
  (:body (first (parse (str "fn f() " src)))))

(defn- expr-of [src]
  (:tail (body-of (str "{ " src " }"))))

(defn- shape
  "A compact s-expression of an expression AST, for precedence tests."
  [e]
  (case (:e e)
    :int (:v e)
    :path (symbol (:name e))
    :binary (list (symbol (:op e)) (shape (:l e)) (shape (:r e)))
    :unary (list (symbol (:op e)) (shape (:x e)))
    :call (list* 'call (shape (:callee e)) (map shape (:args e)))
    :mcall (list* 'mcall (shape (:recv e)) (symbol (:name e)) (map shape (:args e)))
    :field (list 'field (shape (:x e)) (symbol (:name e)))
    :index (list 'index (shape (:x e)) (shape (:i e)))
    (:e e)))

(deftest precedence
  (are [src expected] (= expected (pr-str (shape (expr-of src))))
    "1 + 2 * 3" "(+ 1 (* 2 3))"
    "1 - 2 - 3" "(- (- 1 2) 3)"
    "a & b == c" "(== (& a b) c)"
    "a | b ^ c & d" "(| a (^ b (& c d)))"
    "a << 1 + 2" "(<< a (+ 1 2))"
    "a || b && c" "(|| a (&& b c))"
    "-a * b" "(* (- a) b)"
    "!a == b" "(== (! a) b)"
    "f(x)[1].y" "(field (index (call f x) 1) y)"
    "a.m(1, 2).n" "(field (mcall a m 1 2) n)"
    "(1 + 2) * 3" "(* (+ 1 2) 3)"))

(deftest comparison-is-non-associative
  (is (= "error: parse at 1:24" (parse-error "fn f() { let x = 1 < 2 < 3; }"))))

(deftest statement-termination
  (testing "an if/match statement needs no semicolon"
    (let [b (body-of "{ if a { b } else { c } d }")]
      (is (= 1 (count (:stmts b))))
      (is (= :path (:e (:tail b))))))
  (testing "a following parenthesis continues the if expression"
    (let [b (body-of "{ if a { f() } else { g() } (1, 2); }")]
      (is (= :call (:e (:expr (first (:stmts b))))))))
  (testing "other expressions need one"
    (is (= "error: parse at 1:16" (parse-error "fn f() { 1 + 2 3 }")))))

(deftest items
  (let [[use-item struct-item fn-item] (parse "use m as k;\npub struct P<A, B> { a: A, b: [B], }\nfn f<T: Eq + Ord>(x: T, y: #[Str: (Int, Int)]) -> fn(Int) -> Int { }")]
    (is (= {:i :use :name "m" :alias "k"} (select-keys use-item [:i :name :alias])))
    (is (= ["P" true 2 2] [(:name struct-item) (:pub struct-item) (count (:tparams struct-item))
                           (count (:fields struct-item))]))
    (is (= ["f" 2 2] [(:name fn-item) (count (:params fn-item)) (count (:bounds (first (:tparams fn-item))))]))
    (is (= :fn (:ty (:ret fn-item))))))

(deftest nested-generic-closers
  (let [[f] (parse "fn f(x: Option<Option<Int>>, y: Result<[Int], Option<Str>>) {}")]
    (is (= 2 (count (:params f))))))

(deftest patterns
  (let [arms (:arms (expr-of "match x { _ -> 1, -5 -> 2, (a, b) -> 3, [h, ..t] -> 4, P.{ f, g: 1, .. } -> 5, Some(x) -> 6, m::C -> 7, y -> 8 }"))]
    (is (= [:wild :lit :tuple :list :struct :variant :variant :name] (map #(:p (:pat %)) arms)))
    (is (= -5 (:v (:pat (second arms)))))))

(deftest parse-errors
  (are [src expected] (= expected (parse-error src))
    "fn f( {" "error: parse at 1:7"
    "fn f() { let (x) = 1; }" "error: parse at 1:16"
    "struct S<T: Eq> {}" "error: parse at 1:11"
    "impl Eq for Int { pub fn m(self) {} }" "error: parse at 1:19"
    "fn f() { let x = | | 8; }" "error: parse at 1:20"
    "fn f() { match x { [.., b] -> 1 } }" "error: parse at 1:23"
    "fn f()" "error: parse at 1:7"))
