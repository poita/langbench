(ns template.parser-test
  (:require [clojure.test :refer [deftest is testing]]
            [template.core :as core]
            [template.lexer :as lexer]
            [template.parser :as parser]))

(defn- kind [src]
  (try (parser/parse src) nil
       (catch clojure.lang.ExceptionInfo e (core/error-kind e))))

(deftest lexer-whitespace-control
  (is (= [[:text "a"] [:print [[:name "x"]]] [:text "b"]]
         (lexer/lex "a  {{- x -}}  b")))
  (is (= [[:text "a"] [:text "b"]] (lexer/lex "a  {#- comment -#}  b")))
  (is (= [[:text "a "] [:print [[:name "x"]]]] (lexer/lex "a {{ x }}")))
  (testing "whitespace is not removed across another tag"
    (is (= [[:print [[:name "x"]]] [:text "|"] [:print [[:name "y"]]]]
           (lexer/lex "{{ x }}|{{ y }}")))
    (is (= [[:print [[:name "x"]]] [:print [[:name "y"]]]]
           (lexer/lex "{{ x -}} {{- y }}"))
        "a text consisting only of whitespace between two stripping tags vanishes")))

(deftest lexer-tokens
  (is (= [[:int 1] [:op "**"] [:float 2.5] [:op "//"] [:str "a\"b\n"] [:op "!="]]
         (second (first (lexer/lex "{{ 1 ** 2.5 // 'a\"b\\n' != }}")))))
  (testing "closer is recognised before the minus operator"
    (is (= [[:name "x"]] (second (first (lexer/lex "{{ x -}}")))))
    (is (= :syntax (kind "{{ x - }}"))))
  (testing "string literals may contain closers"
    (is (= [[:str "%}"]] (second (first (lexer/lex "{% \"%}\" %}")))))))

(deftest syntax-errors
  (doseq [src ["{{ x" "{% if x %}" "{# unclosed" "{% endif %}" "{% for a, b in x %}{% endfor %}"
               "{{{ x }}}" "{{ 'abc }}" "{{ 'a\\qb' }}" "{% raw %}" "{% %}" "{{ a if b else c }}"
               "{{ x is foo }}" "{% block a %}{% endblock b %}" "{% block a %}{% endblock %}{% block a %}{% endblock %}"
               "{% if x %}{% else %}{% elif y %}{% endif %}" "{% for x in y %}{% endfor extra %}"
               "{% set a, b = 1 %}" "{% if x %}{% extends 'a' %}{% endif %}"
               "{% extends 'a' %}{% extends 'b' %}" "{{ f(a=1, 2) }}" "{{ f(a=1, a=2) }}"
               "{% macro m(a, a) %}{% endmacro %}" "{{ [1,] }}" "{{ x|f(1,) }}" "{{ (1, 2) }}"
               "{% include 'a' ignore missing %}" "{{ 1 +}}" "{{ x.1 }}" "{% for true in x %}{% endfor %}"]]
    (is (= :syntax (kind src)) src)))

(deftest valid-templates
  (doseq [src ["" "text {x} } {" "{{ -x|int }}" "{{ a < b < c }}" "{{ not a in b }}"
               "{{ a not in b }}" "{% macro m(a, b=a|upper) %}{% endmacro %}"
               "{% block a %}{% block b %}{% endblock b %}{% endblock a %}"
               "{{ x is not defined }}" "{{ f(1, k=2) }}" "{% if a %}{% elif b %}{% else %}{% endif %}"]]
    (is (nil? (kind src)) src)))

(deftest filter-check-after-syntax
  (is (= :filter (kind "{% if false %}{{ x|nope }}{% endif %}")))
  (is (= :syntax (kind "{{ x|nope }}{% if %}")))
  (is (= :filter (kind "{% macro m(a=1|bogus) %}{% endmacro %}"))))

(deftest tree-shape
  (is (= {:body [[:print [:binop :add [:lit 1] [:binop :mul [:lit 2] [:lit 3]]]]] :blocks {}}
         (parser/parse "{{ 1 + 2 * 3 }}")))
  (testing "filters bind tighter than binary operators, looser than unary minus"
    (is (= [[:print [:binop :mul [:name "a"] [:filter [:name "b"] "int" []]]]]
           (:body (parser/parse "{{ a * b|int }}"))))
    (is (= [[:print [:filter [:neg [:name "x"]] "int" []]]]
           (:body (parser/parse "{{ -x|int }}")))))
  (testing "** is left associative"
    (is (= [[:print [:binop :pow [:binop :pow [:lit 2] [:lit 3]] [:lit 2]]]]
           (:body (parser/parse "{{ 2 ** 3 ** 2 }}"))))))
