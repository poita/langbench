(ns buildsys.parser-test
  (:require [buildsys.errors :as e]
            [buildsys.lexer :as lex]
            [buildsys.parser :as parser]
            [clojure.test :refer [deftest is testing]]))

(defn- parse-error
  "The E_PARSE detail raised for `src`, or nil when it parses."
  [src]
  (try (parser/parse-file "f.kiln" src) nil
       (catch clojure.lang.ExceptionInfo ex (ex-message ex))))

(deftest lexical-structure
  (testing "comments, strings and logical lines"
    (is (= [{:line 1 :tokens [[:id "let"] [:id "x"] [:sym "="] [:str "\"a#b\""]]}]
           (lex/lex-file "let x = \"a#b\" # comment\n")))
    (is (= [{:line 1 :tokens [[:id "f"] [:sym "("] [:int 1] [:sym ","] [:int 2] [:sym ")"]]}]
           (lex/lex-file "f(1,\n  2)\n")))
    (is (= [{:line 3 :tokens [[:id "x"]]}] (lex/lex-file "\n# nothing\nx\n"))))
  (testing "operators match longest first"
    (is (= [[:sym "|>"] [:sym "||"] [:sym "++"] [:sym "<="] [:sym "=="]]
           (lex/tokenize "|> || ++ <= =="))))
  (testing "string literal reader"
    (is (= ["a\nb\t\"\\{}"] (lex/read-literal "\"a\\nb\\t\\\"\\\\{{}}\"")))
    (is (= ["it's {x}"] (lex/read-literal "'it''s {x}'")))
    (is (= 3 (count (lex/read-literal "\"a{1 + 2}b\""))))))

(deftest which-parse-error-is-reported
  (is (= "E_PARSE f.kiln:1" (parse-error "let b = f(\n  \"unterminated\n)\n")))
  (testing "lexical errors beat earlier grammar errors"
    (is (= "E_PARSE f.kiln:2" (parse-error "let = 1\nlet x = \"abc\n"))))
  (testing "unterminated blocks are reported last, at the innermost header"
    (is (= "E_PARSE f.kiln:2" (parse-error "when true {\neach x in [] {\n"))))
  (testing "errors inside literals belong to the logical line"
    (is (= "E_PARSE f.kiln:1" (parse-error "let x = \"a}b\"\n")))
    (is (= "E_PARSE f.kiln:1" (parse-error "let x = \"{ }\"\n")))
    (is (= "E_PARSE f.kiln:1" (parse-error "let x = \"\\q\"\n")))))

(deftest block-layout
  (is (nil? (parse-error "when true {\n} elsewhen false {\n} otherwise {\n}\n")))
  (doseq [src ["}\n" "{\n" "when true {\n} otherwise {\n} elsewhen true {\n}\n"
               "step {\n} otherwise {\n}\n" "when true {\n} foo\n"
               "step {\n step {\n}\n}\n" "out \"out/x\"\n" "step {\n let x = 1\n}\n"]]
    (is (parser/parse-file "f" "") "sanity")
    (is (some? (parse-error src)) (pr-str src))))

(deftest grammar-restrictions
  (doseq [src ["let cost = 1" "let x = f(1)(2)" "let x = (f)(1)" "let x = 1 |> 2"
               "each i, i in [] {\n}" "rule r(a, a) {\n}" "rule r(a = 1, b) {\n}"
               "use r(a = 1, 2)" "let x = 1 2" "let x = |" "let x = a & b"
               "let x = ["]]
    (is (some? (parse-error (str src "\n"))) src))
  (testing "reserved words are call names but not variables"
    (is (nil? (parse-error "let x = 1 |> cost\n")))
    (is (nil? (parse-error "let x = true(1)\n")))
    (is (some? (parse-error "let x = out\n")))))

(deftest precedence
  (let [expr (fn [src] (:expr (first (parser/parse-file "f" (str "let x = " src "\n")))))]
    (is (= [:bin "+" [:const 1] [:bin "*" [:const 2] [:const 3]]] (expr "1 + 2 * 3")))
    (is (= [:bin "-" [:bin "-" [:const 1] [:const 2]] [:const 3]] (expr "1 - 2 - 3")))
    (is (= [:call "g" [[:call "f" [[:var "x"]]] [:const 1]]] (expr "x |> f |> g(1)")))
    (is (= [:or [:var "a"] [:and [:var "b"] [:var "c"]]] (expr "a || b && c")))))
