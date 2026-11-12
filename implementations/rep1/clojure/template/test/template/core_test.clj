(ns template.core-test
  (:require [clojure.test :refer [deftest is testing]]
            [clojure.test.check.clojure-test :refer [defspec]]
            [clojure.test.check.generators :as gen]
            [clojure.test.check.properties :as prop]
            [template.core :as core]))

(defn- r
  ([src] (core/render-string src {}))
  ([src ctx] (core/render-string src ctx)))

(defn- kind
  ([src] (kind src {}))
  ([src ctx] (try (r src ctx) nil (catch clojure.lang.ExceptionInfo e (core/error-kind e)))))

(deftest text-and-variables
  (is (= "" (r "")))
  (is (= "plain { } text" (r "plain { } text")))
  (is (= "Hello ADA!" (r "Hello {{ name|upper }}!" {:name "ada"})))
  (is (= "x" (r "{# comment #}x{#- another -#}")))
  (is (= "a|b" (r "a {{- '|' -}} b"))))

(deftest literals-and-operators
  (is (= "3 3.5 3 -4 2 1.0 8" (r "{{ 1 + 2 }} {{ 7 / 2 }} {{ 7 // 2 }} {{ -7 // 2 }} {{ -7 % 3 }} {{ 2 ** 0 / 1 }} {{ 2 ** 3 }}")))
  (is (= "4 0.5" (r "{{ -2 ** 2 }} {{ 2 ** -1 }}")))
  (is (= "x" (r "{{ 0 or 'x' }}")))
  (is (= "" (r "{{ '' and 1 }}")))
  (is (= "2" (r "{{ 1 and 2 }}")))
  (is (= "True False True" (r "{{ 1 == 1.0 }} {{ 1 == '1' }} {{ true == 1 }}")))
  (is (= "True False" (r "{{ 1 < 2 < 3 }} {{ 3 < 2 < 1 / 0 }}")))
  (is (= "True True" (r "{{ 'a' in 'abc' }} {{ 'x' not in ['a'] }}")))
  (is (= "ab12" (r "{{ 'a' ~ 'b' ~ 1 ~ 2 }}")))
  (is (= "[1, 'a', True, None]" (r "{{ [1, 'a', true, none] }}"))))

(deftest access
  (let [ctx {:a {:b [10 20 30] :s "héllo"}}]
    (is (= "20 30 é" (r "{{ a.b[1] }} {{ a.b[-1] }} {{ a.s[1] }}" ctx)))
    (is (= "False" (r "{{ a.zzz is defined }}" ctx)))
    (is (= "x" (r "{{ a.zzz|default('x') }}" ctx)))
    (is (= "True" (r "{{ a.b[3] is not defined }}" ctx)))
    (is (= :undefined (kind "{{ a.zzz.y }}" ctx)))))

(deftest control-flow
  (is (= "1. x\n2. y\n" (r "{% for t in l %}{{ loop.index }}. {{ t }}\n{% endfor %}" {:l ["x" "y"]})))
  (is (= "empty" (r "{% for t in l %}x{% else %}empty{% endfor %}" {:l []})))
  (is (= "012" (r "{% for i in range(3) %}{{ i }}{% endfor %}")))
  (is (= "321" (r "{% for i in range(3, 0, -1) %}{{ i }}{% endfor %}")))
  (is (= "abc" (r "{% for c in 'abc' %}{{ c }}{% endfor %}")))
  (is (= "ab" (r "{% for k in d %}{{ k }}{% endfor %}" {:d (array-map "a" 1 "b" 2)})))
  (is (= "T F L" (r "{% for x in [1, 2] %}{% if loop.first %}T{% endif %}{% if loop.last %} L{% else %} F{% endif %}{% endfor %}")))
  (is (= "11 12 21 22" (r "{% for i in [1, 2] %}{% for j in [1, 2] %}{{ i }}{{ j }}{% if not (i == 2 and j == 2) %} {% endif %}{% endfor %}{% endfor %}")))
  (is (= "b" (r "{% if x == 1 %}a{% elif x == 2 %}b{% else %}c{% endif %}" {:x 2})))
  (is (= "c" (r "{% if x == 1 %}a{% elif x == 2 %}b{% else %}c{% endif %}" {:x 3}))))

(deftest scoping
  (testing "set inside a loop body is local to the iteration"
    (is (= "123|False" (r "{% for i in [1,2,3] %}{% set y = i %}{{ y }}{% endfor %}|{{ y is defined }}"))))
  (testing "top-level set"
    (is (= "5" (r "{% set a = 2 %}{% set b = a + 3 %}{{ b }}"))))
  (testing "loop is not defined outside a loop"
    (is (= :undefined (kind "{{ loop.index }}"))))
  (testing "the inner loop variable wins"
    (is (= "1a2b1a2b" (r "{% for i in [1,2] %}{% for j in ['a','b'] %}{{ loop.index }}{{ j }}{% endfor %}{% endfor %}"))
        "loop refers to the innermost loop")))

(deftest macros
  (is (= "#1#2" (r "{% macro item(v) %}#{{ v }}{% endmacro %}{{ item(1) }}{{ item(2) }}")))
  (is (= "Hi Bob!" (r "{% macro hi(n, g='Hi') %}{{ g }} {{ n }}!{% endmacro %}{{ hi('Bob') }}")))
  (is (= "Yo Bob!" (r "{% macro hi(n, g='Hi') %}{{ g }} {{ n }}!{% endmacro %}{{ hi('Bob', g='Yo') }}")))
  (is (= "ab" (r "{% macro m(a, b=a) %}{{ a }}{{ b }}{% endmacro %}{{ m('a', b='b') }}")))
  (is (= "120" (r "{% macro f(n) %}{% if n <= 1 %}1{% else %}{{ n * f(n - 1)|int }}{% endif %}{% endmacro %}{{ f(5) }}"))
      "recursive macros return strings")
  (is (= "x" (r "{% set v = 'x' %}{% macro m() %}{{ v }}{% endmacro %}{{ m() }}")))
  (is (= "x2" (r "{% macro m() %}{{ v }}{% endmacro %}{% set v = 'x2' %}{{ m() }}"))
      "macros see later sets of their defining scope")
  (is (= :undefined (kind "{% macro m(a) %}{{ a }}{% endmacro %}{{ m() }}")))
  (is (= :type (kind "{% macro m(a) %}{% endmacro %}{{ m(1, 2) }}")))
  (is (= :type (kind "{% macro m(a) %}{% endmacro %}{{ m(b=1) }}")))
  (is (= :type (kind "{% macro m(a) %}{% endmacro %}{{ m(1, a=1) }}")))
  (is (= :undefined (kind "{{ nomacro(1) }}")))
  (is (= :type (kind "{{ 'x'(1) }}"))))

(deftest include-and-inheritance
  (let [ts {"main" "{% extends 'page' %}{% block title %}[{{ super() }}]{% endblock %}"
            "page" "<{% block title %}T{% endblock %}|{% block body %}B{% endblock %}>"}]
    (is (= "<[T]|B>" (core/render ts "main" {}))))
  (let [ts {"main" "{% extends 'mid' %}{% block b %}main({{ super() }}){% endblock %}"
            "mid" "{% extends 'base' %}{% block b %}mid({{ super() }}){% endblock %}"
            "base" "{% block b %}base{% endblock %}"}]
    (is (= "main(mid(base))" (core/render ts "main" {}))))
  (testing "output before extends is kept, text after it is dropped"
    (is (= "pre<b>" (core/render {"c" "pre{% extends 'p' %}ignored{{ x }}" "p" "<b>"} "c" {}))))
  (testing "set and macro after extends take effect"
    (is (= "<3 #1>" (core/render {"c" "{% extends 'p' %}{% set n = 3 %}{% block b %}{{ n }} {{ m(1) }}{% endblock %}"
                                  "p" "{% macro m(v) %}#{{ v }}{% endmacro %}<{% block b %}{% endblock %}>"} "c" {}))))
  (testing "include sees the includer's scope but not vice versa"
    (is (= "x-1|False" (core/render {"m" "{% set a = 1 %}x-{% include 'i' %}|{{ b is defined }}"
                                "i" "{{ a }}{% set b = 2 %}"} "m" {}))
        "b is invisible to the includer, so `b is defined` is False")
    )
  (testing "blocks do not see loop variables"
    (is (= :undefined (kind "{% for i in [1] %}{% endfor %}{% block b %}{{ i }}{% endblock %}"))))
  (is (= :undefined (kind "{% block b %}{{ super() }}{% endblock %}")))
  (is (= :template (try (core/render {"m" "{% include 'nope' %}"} "m" {})
                        (catch clojure.lang.ExceptionInfo e (core/error-kind e)))))
  (is (= :type (kind "{% include 1 %}")))
  (is (= :undefined (kind "{% include missing %}")))
  (testing "unused templates are never checked"
    (is (= "ok" (core/render {"m" "ok" "broken" "{% if %}"} "m" {}))))
  (testing "errors in included templates surface when they run"
    (is (= :syntax (try (core/render {"m" "a{% include 'b' %}" "b" "{% if %}"} "m" {})
                        (catch clojure.lang.ExceptionInfo e (core/error-kind e)))))
    (is (= :filter (try (core/render {"m" "a{% include 'b' %}" "b" "{{ 1|nope }}"} "m" {})
                        (catch clojure.lang.ExceptionInfo e (core/error-kind e)))))))

(deftest error-kinds
  (is (= :syntax (kind "{% for x in y %}")))
  (is (= :filter (kind "{{ 1|nope }}")))
  (is (= :undefined (kind "{{ nothing }}")))
  (is (= :undefined (kind "{% if nothing %}{% endif %}")))
  (is (= :undefined (kind "{{ nothing == 1 }}")))
  (is (= :type (kind "{{ 1 / 0 }}")))
  (is (= :type (kind "{% for x in 5 %}{% endfor %}")))
  (is (= :type (kind "{{ range('a') }}")))
  (is (= :type (kind "{{ range(1, 2, 0) }}")))
  (testing "argument errors win over a bad callee"
    (is (= :type (kind "{{ nomacro(1 / 0) }}"))))
  (testing "the first error wins"
    (is (= :undefined (kind "{{ a }}{{ 1 / 0 }}")))))

(deftest api
  (is (= "1 2" (core/render-json {"m" "{{ a }} {{ b }}"} "m" "{\"a\": 1, \"b\": 2}")))
  (is (= "x\ny" (core/render-input "{}\n--\n=== main\nx\ny")))
  (is (= :syntax (core/error-kind (try (core/parse-template "{{") (catch Exception e e))))))

(defspec printing-integers 200
  (prop/for-all [n gen/small-integer]
    (= (str n) (r "{{ n }}" {:n n}))))

(defspec arithmetic-agrees-with-clojure 200
  (prop/for-all [a gen/small-integer b gen/small-integer]
    (= (str (+ a (* 2 b)) "|" (- a b))
       (r "{{ a + 2 * b }}|{{ a - b }}" {:a a :b b}))))

(defspec list-printing-round-trip 100
  (prop/for-all [xs (gen/vector gen/small-integer)]
    (= (str "[" (clojure.string/join ", " xs) "]") (r "{{ xs }}" {:xs xs}))))

(defspec join-and-length 100
  (prop/for-all [xs (gen/vector gen/string-alphanumeric)]
    (= (str (count xs) ":" (clojure.string/join "," xs))
       (r "{{ xs|length }}:{{ xs|join(',') }}" {:xs xs}))))
