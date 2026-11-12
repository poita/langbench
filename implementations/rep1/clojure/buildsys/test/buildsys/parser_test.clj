(ns buildsys.parser-test
  (:require [buildsys.error :as err]
            [buildsys.lexer :as lexer]
            [buildsys.parser :as parser]
            [clojure.test :refer [deftest is testing]]))

(defn- parse-error
  "The E_PARSE detail raised for `text`, or nil when it parses."
  [text]
  (try (parser/parse-file "f.kiln" text) nil
       (catch clojure.lang.ExceptionInfo e
         (when (err/kiln-error? e)
           (is (= "E_PARSE" (:kind (ex-data e))))
           (:detail (ex-data e))))))

(deftest lexical-stages
  (testing "comments are stripped but not inside strings"
    (is (= [{:line 1 :tokens [[:id "let"] [:id "x"] [:op "="] [:str "\"a # b\""]]}]
           (lexer/lex "f" "let x = \"a # b\" # comment\n"))))
  (testing "bracketed lines join and report their first line number"
    (is (= [{:line 1 :tokens [[:id "f"] [:op "("] [:int 1] [:op ","] [:int 2] [:op ")"]]}
            {:line 4 :tokens [[:id "g"]]}]
           (lexer/lex "f" "f(1,\n  2\n)\ng\n"))))
  (testing "a literal may contain nested literals inside an interpolation"
    (is (= 1 (count (lexer/lex "f" "cmd write(\"{join(xs, \", \")}\\n\")\n")))))
  (testing "operators are matched longest first"
    (is (= [[:op "|>"] [:op "||"] [:op "<="] [:op "++"] [:op "<"]]
           (lexer/tokenize "|> || <= ++ <" #(throw (ex-info "bad" {})))))))

(deftest lexical-errors
  (is (= "f.kiln:1" (parse-error "let b = f(\n  \"unterminated\n)\n")))
  (is (= "f.kiln:1" (parse-error "x = (1\n")))
  (is (= "f.kiln:1" (parse-error ")\n")))
  (is (= "f.kiln:2" (parse-error "let a = 1\nlet b = 1 | 2\n")))
  (is (= "f.kiln:1" (parse-error "let b = 1 & 2\n")))
  (is (= "f.kiln:1" (parse-error "let b = $\n"))))

(deftest lexical-errors-beat-grammar-errors
  (is (= "f.kiln:2" (parse-error "let = 1\nlet x = \"abc\n"))))

(deftest grammar-errors
  (is (= "f.kiln:1" (parse-error "let = 1\n")))
  (is (= "f.kiln:1" (parse-error "let in = 1\n")))
  (is (= "f.kiln:1" (parse-error "out \"x\"\n")))
  (is (= "f.kiln:2" (parse-error "step {\n let x = 1\n}\n")))
  (is (= "f.kiln:1" (parse-error "let x = 1 2\n")))
  (is (= "f.kiln:1" (parse-error "let x = (1)(2)\n")))
  (is (= "f.kiln:1" (parse-error "let x = \"a\\q\"\n")))
  (is (= "f.kiln:1" (parse-error "let x = \"a}b\"\n")))
  (is (= "f.kiln:1" (parse-error "let x = \"{}\"\n")))
  (is (= "f.kiln:1" (parse-error "let x = \"{ }\"\n")))
  (is (= "f.kiln:1" (parse-error "let x = \"{1 2}\"\n")))
  (is (= "f.kiln:1" (parse-error "each a, a in [] {\n}\n")))
  (is (= "f.kiln:1" (parse-error "rule r(a, a) {\n}\n")))
  (is (= "f.kiln:1" (parse-error "rule r(a = 1, b) {\n}\n")))
  (is (= "f.kiln:1" (parse-error "use r(a = 1, 2)\n")))
  (is (= "f.kiln:1" (parse-error "{\n")))
  (is (= "f.kiln:1" (parse-error "}\n")))
  (is (= "f.kiln:2" (parse-error "when true {\n} foo\n")))
  (is (= "f.kiln:3" (parse-error "when true {\n} otherwise {\n} otherwise {\n}\n")))
  (is (= "f.kiln:2" (parse-error "each x in [] {\n} otherwise {\n}\n"))))

(deftest reserved-words
  (testing "reserved words are rejected as names"
    (doseq [t ["let cost = 1" "set out = 1" "phony in = []" "rule step() {\n}"
               "rule r(after) {\n}" "let x = cost" "use r(cost = 1)"]]
      (is (some? (parse-error (str t "\n"))) t)))
  (testing "but are fine as call names, command names and rule names"
    (is (nil? (parse-error "let x = cost(1)\nlet y = 1 |> cost\nuse set()\n")))
    (is (nil? (parse-error "step {\n cmd out()\n}\n")))))

(deftest unterminated-blocks
  (is (= "f.kiln:2" (parse-error "let a = 1\nstep {\n out \"x\"\n")))
  (is (= "f.kiln:2" (parse-error "when true {\neach x in [] {\n")) "innermost wins when two are open")
  (is (= "f.kiln:2" (parse-error "when true {\n} elsewhen true {\nlet x = 1\n"))
      "a `} elsewhen` line is itself a header")
  (is (= "f.kiln:1" (parse-error "when true {\neach x in [] {\n}\n")) "a closed inner block is not reported")
  (testing "any other error wins over an unterminated block"
    (is (= "f.kiln:3" (parse-error "step {\n out \"x\"\n let = 1\n")))))

(deftest ast-shapes
  (is (= [[:let "x" [:binop "+" [:lit 1] [:binop "*" [:lit 2] [:lit 3]]]]]
         (parser/parse-file "f" "let x = 1 + 2 * 3\n")))
  (is (= [[:let "x" [:call "g" [[:call "f" [[:var "a"]]] [:lit 1]]]]]
         (parser/parse-file "f" "let x = a |> f |> g(1)\n")))
  (is (= [[:let "s" [:interp ["a" [:var "n"] "b{"]]]]
         (parser/parse-file "f" "let s = \"a{n}b{{\"\n")))
  (is (= [[:let "s" [:lit "it's \\n {x}"]]]
         (parser/parse-file "f" "let s = 'it''s \\n {x}'\n")))
  (is (= [[:when [[[:var "a"] [[:let "x" [:lit 1]]]] [[:var "b"] []]] [[:abort [:lit "no"]]]]]
         (parser/parse-file "f" "when a {\nlet x = 1\n} elsewhen b {\n} otherwise {\nabort \"no\"\n}\n")))
  (is (= [[:each "i" "n" [:var "xs"] []]]
         (parser/parse-file "f" "each i, n in xs {\n}\n")))
  (is (= [[:rule "r" [{:name "a" :default nil} {:name "b" :default [:lit 2]}] []]]
         (parser/parse-file "f" "rule r(a, b = 2,) {\n}\n")))
  (is (= [[:use "r" [[:pos [:lit 1]] [:kw "k" [:lit 2]]]]]
         (parser/parse-file "f" "use r(1, k = 2)\n"))))
