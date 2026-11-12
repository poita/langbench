(ns sitegen.template-test
  (:require [clojure.string :as str]
            [clojure.test :refer [deftest is testing]]
            [clojure.test.check.clojure-test :refer [defspec]]
            [clojure.test.check.generators :as gen]
            [clojure.test.check.properties :as prop]
            [sitegen.template :as tpl])
  (:import (java.util LinkedHashMap)))

(defn- dict [& kvs]
  (let [m (LinkedHashMap.)]
    (doseq [[k v] (partition 2 kvs)] (.put m k v))
    m))

(def ^:private context
  (dict "n" 7 "neg" -7 "f" 2.5 "s" "Hello" "t" "  pad  " "items" [3 1 2] "words" ["b" "A" "c"]
        "empty" [] "d" (dict "a" 1 "b" "x") "big" 1.0E15 "tiny" 1.0E-5 "yes" true "nothing" nil))

(defn- render
  "Renders the template `main` (with other `templates`) against `ctx`."
  ([main] (render main {}))
  ([main templates] (render main templates context))
  ([main templates ctx]
   (tpl/render (tpl/make-env (assoc templates "main" main)) "main" ctx)))

(defn- render-named
  "Renders the template called `name` among `templates`."
  [templates name ctx]
  (tpl/render (tpl/make-env templates) name ctx))

(defn- kind
  "The error kind raised by rendering `main`, or nil when it renders."
  ([main] (kind main {}))
  ([main templates]
   (try (render main templates) nil
        (catch clojure.lang.ExceptionInfo e (tpl/error-kind e)))))

;; Expected values below were produced by Jinja2 3.1 (StrictUndefined).
(def ^:private expression-table
  [
   ["n + 1" "8"]
   ["n - 10" "-3"]
   ["n * 3" "21"]
   ["n / 2" "3.5"]
   ["6 / 3" "2.0"]
   ["n // 2" "3"]
   ["neg // 2" "-4"]
   ["neg % 3" "2"]
   ["n % -3" "-2"]
   ["2 ** 10" "1024"]
   ["2 ** -1" "0.5"]
   ["-2 ** 2" "4"]
   ["f * 2" "5.0"]
   ["f // 1" "2.0"]
   ["7.0 // 2" "3.0"]
   ["0.1 + 0.2" "0.30000000000000004"]
   ["1 / 3" "0.3333333333333333"]
   ["big" "1000000000000000.0"]
   ["big * 10" "1e+16"]
   ["tiny" "1e-05"]
   ["3.0" "3.0"]
   ["100.0 / 3" "33.333333333333336"]
   ["s ~ n" "Hello7"]
   ["s * 2" "HelloHello"]
   ["2 * s" "HelloHello"]
   ["items + [4]" "[3, 1, 2, 4]"]
   ["s|upper" "HELLO"]
   ["s|lower" "hello"]
   ["t|trim" "pad"]
   ["\"<a href=\\\"x\\\">&'\"|escape" "&lt;a href=&#34;x&#34;&gt;&amp;&#39;"]
   ["\"banana\"|replace(\"an\", \"AN\")" "bANANa"]
   ["s|length" "5"]
   ["items|length" "3"]
   ["d|length" "2"]
   ["\"\u00e9\"|length" "1"]
   ["\"3\"|int" "3"]
   ["\" 42 \"|int" "42"]
   ["\"3.9\"|int" "3"]
   ["\"x\"|int" "0"]
   ["\"-3.9\"|int" "-3"]
   ["f|int" "2"]
   ["yes|int" "1"]
   ["items|join(\", \")" "3, 1, 2"]
   ["items|join" "312"]
   ["words|sort" "['A', 'b', 'c']"]
   ["words|sort|join" "Abc"]
   ["items|sort|reverse|join(\"\")" "321"]
   ["\"abc\"|reverse" "cba"]
   ["words|first" "b"]
   ["words|last" "c"]
   ["empty|first|default(\"none\")" "none"]
   ["missing|default(\"dflt\")" "dflt"]
   ["n|default(\"dflt\")" "7"]
   ["n > 3" "True"]
   ["n < 3 < 10" "False"]
   ["1 < 2 < 3" "True"]
   ["3 > 2 > 2" "False"]
   ["n == 7.0" "True"]
   ["yes == 1" "True"]
   ["\"a\" == \"a\"" "True"]
   ["\"a\" < \"b\"" "True"]
   ["items == [3, 1, 2]" "True"]
   ["n in items" "False"]
   ["2 in items" "True"]
   ["\"el\" in s" "True"]
   ["\"a\" in d" "True"]
   ["\"z\" in d" "False"]
   ["\"a\" not in d" "False"]
   ["n and s" "Hello"]
   ["0 or \"x\"" "x"]
   ["\"\" and 1" ""]
   ["not n" "False"]
   ["not 0" "True"]
   ["1 and 2" "2"]
   ["items[0]" "3"]
   ["items[-1]" "2"]
   ["items[5] is defined" "False"]
   ["s[0]" "H"]
   ["s[-1]" "o"]
   ["d.a" "1"]
   ["d[\"b\"]" "x"]
   ["d.zz is defined" "False"]
   ["d.zz is not defined" "True"]
   ["nothing is defined" "True"]
   ["nothing" "None"]
   ["yes" "True"]
   ["not yes" "False"]
   ["[1, \"a\", true, none, 1.5, \"it's\"]" "[1, 'a', True, None, 1.5, \"it's\"]"]
   ["[]" "[]"]
   ["d" "{'a': 1, 'b': 'x'}"]
   ["words" "['b', 'A', 'c']"]
   ["\"it's\"" "it's"]
   ["[ \"q\\\"\" ]" "['q\"']"]
   ["[[1, [2]]]" "[[1, [2]]]"]
   ["range(3)|join(\",\")" "0,1,2"]
   ["range(1, 10, 3)|join(\",\")" "1,4,7"]
   ["range(5, 0, -2)|join(\",\")" "5,3,1"]
   ["items|sort|first" "1"]
   ["\"a-b\"|replace(\"-\", \"\")" "ab"]
   ["n ~ f" "72.5"]
   ["f ~ f" "2.52.5"]
   ["-n" "-7"]
   ["-(-n)" "7"]
   ["n % 3 * 2" "2"]
   ["2 * 3 % 4" "2"]
   ["10 - 2 - 3" "5"]
   ["2 ** 3 ** 2" "64"]
   ["100 // 7 // 2" "7"]
   ["7 // 2 * 2 + 7 % 2" "7"]])

(deftest expressions
  (doseq [[expr expected] expression-table]
    (testing expr
      (is (= expected (render (str "{{ " expr " }}")))))))

(deftest spec-examples
  (testing "block inheritance, macros, include and super"
    (let [templates {"page" (str "{% extends \"base\" %}\n{% set count = items|length %}\n"
                                 "{% block body %}{{ super() }}<ul>{% for i in items|sort %}<li>{{ item(i) }}</li>{% endfor %}</ul>{% endblock %}")
                     "base" (str "{% macro item(v) %}#{{ v }}{% endmacro -%}\n<h1>{% block title %}{{ title }}{% endblock %}</h1>\n"
                                 "{% block body %}{{ count }} items{% endblock %}\n{% include \"footer\" %}")
                     "footer" "-- {{ title|lower }} {{ missing|default(\"end\") }}"}]
      (is (= "<h1>T</h1>\n3 items<ul><li>#1</li><li>#2</li><li>#3</li></ul>\n-- t end"
             (render-named templates "page" (dict "title" "T" "items" [3 1 2]))))))
  (testing "loops, whitespace control, conditions and printing"
    (is (= "Hi ADA!\n1. x\n2. y\nbig 3.5 3 [3, 's']"
           (render (str "Hi {{ user.name|upper }}!\n{% for t in user.tags -%}\n  {{ loop.index }}. {{ t }}\n{% endfor -%}\n"
                        "{% if n > 2 and user.tags|length == 2 %}big{% elif n %}small{% else %}none{% endif %} {{ 7 / 2 }} {{ 7 // 2 }} {{ [n, \"s\"] }}")
                   {} (dict "user" (dict "name" "Ada" "tags" ["x" "y"]) "n" 3)))))
  (testing "an unclosed for is a syntax error even though the greeting could print"
    (is (= :syntax (kind "Hi {{ user.name|upper }}!\n{% for t in user.tags -%}\n  {{ loop.index }}. {{ t }}\n{% if n > 2 %}big{% endif %}"))))
  (testing "attribute access on undefined"
    (is (= :undefined (try (render "{{ a.b }}{{ a.c.d }}" {} (dict "a" (dict "b" 1)))
                           (catch clojure.lang.ExceptionInfo e (tpl/error-kind e)))))))

(deftest whitespace-control
  (is (= "a b" (render "a {{- ' ' -}} b")))
  (is (= "ab" (render "a  {%- if true -%}  b{% endif %}")))
  (is (= "ab" (render "a  \n {#- c -#} \n b")))
  (is (= "x\ny" (render "x\n{# c #}y")))
  (is (= "\n" (render "{% if true %}\n{% endif %}")) "no automatic trimming")
  (is (= "ab" (render "{{ 'a' }}\n  {{- 'b' }}")))
  (is (= "a-" (render "{{ 'a' -}}\n{{ '-' }}")) "only text is trimmed, never across a tag"))

(deftest literals-and-lexing
  (is (= "a\"b'c\\d\n\te" (render "{{ \"a\\\"b'c\\\\d\\n\\te\" }}")))
  (is (= "}}" (render "{{ '}}' }}")) "closers inside strings do not end a tag")
  (is (= "{{{" (render "{{ '{{{' }}")))
  (is (= "{ } {" (render "{ } {")))
  (is (= "12" (render "{{ 1 -}}\n{{ 2 }}")))
  (is (= :syntax (kind "{{ x - }}")))
  (is (= :syntax (kind "{{ 'a\\q' }}")))
  (is (= :syntax (kind "{{{ 1 }}}")))
  (is (= :syntax (kind "{# never closed")))
  (is (= :syntax (kind "{{ 'unterminated }}")))
  (is (= :syntax (kind "{{ 1 +* 2 }}"))))

(deftest statements
  (testing "for: loop variables, else, nesting and scoping"
    (is (= "1/3 2/3 3/3 " (render "{% for i in items %}{{ loop.index }}/{{ loop.length }} {% endfor %}")))
    (is (= "0F 1L " (render "{% for i in [1,2] %}{{ loop.index0 }}{% if loop.first %}F{% endif %}{% if loop.last %}L{% endif %} {% endfor %}")))
    (is (= "none" (render "{% for i in empty %}x{% else %}none{% endfor %}")))
    (is (= "a1a2b1b2" (render "{% for x in ['a','b'] %}{% for y in [1,2] %}{{ x }}{{ y }}{% endfor %}{% endfor %}")))
    (is (= "ab" (render "{% for k in d %}{{ k }}{% endfor %}")) "a dict iterates over its keys")
    (is (= "a,b,c" (render "{% for ch in 'abc' %}{{ ch }}{% if not loop.last %},{% endif %}{% endfor %}")))
    (is (= "5" (render "{% set x = 5 %}{% for i in [1] %}{% set x = 9 %}{% endfor %}{{ x }}"))
        "set inside a loop does not leak out")
    (is (= :undefined (kind "{% for i in [1] %}{% endfor %}{{ loop.index }}"))))
  (testing "if / elif / else"
    (is (= "b" (render "{% if 0 %}a{% elif 1 %}b{% else %}c{% endif %}")))
    (is (= "c" (render "{% if 0 %}a{% elif '' %}b{% else %}c{% endif %}"))))
  (testing "set"
    (is (= "3 4" (render "{% set a = 1 + 2 %}{{ a }} {% set a = a + 1 %}{{ a }}"))))
  (testing "macros"
    (is (= "<1|2>" (render "{% macro m(a, b=2) %}<{{ a }}|{{ b }}>{% endmacro %}{{ m(1) }}")))
    (is (= "<1|5>" (render "{% macro m(a, b=2) %}<{{ a }}|{{ b }}>{% endmacro %}{{ m(1, b=5) }}")))
    (is (= "<3|2>" (render "{% macro m(a, b=2) %}<{{ a }}|{{ b }}>{% endmacro %}{{ m(b=2, a=3) }}")))
    (is (= "<1|1>" (render "{% macro m(a, b=a) %}<{{ a }}|{{ b }}>{% endmacro %}{{ m(1) }}")) "defaults see earlier parameters")
    (is (= "120" (render "{% macro f(n) %}{% if n <= 1 %}1{% else %}{{ n * f(n - 1)|int }}{% endif %}{% endmacro %}{{ f(5) }}")))
    (is (= "d" (render "{% macro m(a) %}{{ a|default('d') }}{% endmacro %}{{ m() }}")))
    (is (= "7" (render "{% macro m() %}{{ n }}{% endmacro %}{% for n in [1] %}{% endfor %}{{ m() }}")) "macros do not see caller locals")
    (is (= :type (kind "{% macro m(a) %}{% endmacro %}{{ m(1, 2) }}")))
    (is (= :type (kind "{% macro m(a) %}{% endmacro %}{{ m(b=2) }}")))
    (is (= :type (kind "{% macro m(a) %}{% endmacro %}{{ m(1, a=2) }}"))))
  (testing "include sees the includer's scope but binds nothing back"
    (is (= "[5]-" (render "{% set x = 5 %}[{% include 'inc' %}]{{ y|default('-') }}" {"inc" "{% set y = 1 %}{{ x }}"}))))
  (testing "range"
    (is (= "0123" (render "{% for i in range(4) %}{{ i }}{% endfor %}")))
    (is (= :type (kind "{{ range(0) }}{{ range(1, 2, 0) }}")))
    (is (= :type (kind "{% for i in range() %}{% endfor %}")))))

(deftest inheritance
  (let [base "[{% block a %}A{% endblock %}|{% block b %}B{% endblock %}]"]
    (testing "override one block"
      (is (= "[A|b2]" (render "{% extends 'base' %}{% block b %}b2{% endblock %}" {"base" base}))))
    (testing "super()"
      (is (= "[A|B+]" (render "{% extends 'base' %}{% block b %}{{ super() }}+{% endblock %}" {"base" base}))))
    (testing "three levels"
      (is (= "[A|B!?]" (render "{% extends 'mid' %}{% block b %}{{ super() }}?{% endblock %}"
                                {"base" base
                                 "mid" "{% extends 'base' %}{% block b %}{{ super() }}!{% endblock %}"}))))
    (testing "output before extends is kept, text after it is dropped"
      (is (= "pre[A|B]" (render "pre{% extends 'base' %}ignored{{ 1/0 }}" {"base" base}))))
    (testing "set and macro after extends still run"
      (is (= "[X|B]" (render "{% extends 'base' %}{% set v = 'X' %}{% block a %}{{ v }}{% endblock %}" {"base" base}))))
    (testing "blocks see top-level macros of the parent"
      (is (= "<1>" (render "{% extends 'base' %}{% block a %}{{ m(1) }}{% endblock %}"
                           {"base" "{% macro m(x) %}<{{ x }}>{% endmacro %}{% block a %}{% endblock %}"}))))
    (testing "super() without a parent block"
      (is (= :undefined (kind "{% block a %}{{ super() }}{% endblock %}"))))
    (testing "a block of the child that the parent lacks is never rendered"
      (is (= "[A|B]" (render "{% extends 'base' %}{% block zzz %}never{% endblock %}" {"base" base}))))))

(deftest errors
  (testing "syntax"
    (doseq [t ["{% if %}x{% endif %}" "{% for a, b in x %}{% endfor %}" "{% foo %}" "{% endif %}" "{% if 1 %}"
               "{% set a, b = 1 %}" "{% include 'x' ignore missing %}" "{{ 1 if 2 else 3 }}"
               "{% block a %}{% endblock b %}" "{% block a %}{% endblock %}{% block a %}{% endblock %}"
               "{% if 1 %}{% extends 'x' %}{% endif %}" "{% extends 'a' %}{% extends 'b' %}"
               "{% macro m(a, a) %}{% endmacro %}" "{{ x is foo }}" "{{ f(a=1, 2) }}" "{{ f(a=1, a=2) }}"
               "{% else %}" "{% %}" "{{ }}" "{% raw %}x{% endraw %}" "{{ {'a': 1} }}" "{{ a[1:2] }}"
               "{% for x in y if z %}{% endfor %}" "{% for x in y %}{% endfor x %}"]]
      (is (= :syntax (kind t)) t)))
  (testing "filter: unknown names are caught at load time, even in dead branches"
    (is (= :filter (kind "{% if false %}{{ 1|nosuch }}{% endif %}")))
    (is (= :filter (kind "{% macro m() %}{{ 1|nosuch }}{% endmacro %}"))))
  (testing "syntax wins over filter"
    (is (= :syntax (kind "{{ 1|nosuch }}{% if %}"))))
  (testing "undefined"
    (doseq [t ["{{ nosuch }}" "{{ nosuch.x }}" "{{ n.nosuch.x }}" "{% if nosuch %}{% endif %}" "{{ nosuch + 1 }}"
               "{{ nosuch == 1 }}" "{{ 1 in nosuch }}" "{{ nosuch|upper }}" "{{ nosuch(1) }}" "{% for x in nosuch %}{% endfor %}"
               "{{ [1][5] }}" "{{ items[9] }}" "{{ words[9]|upper }}" "{% set x = nosuch %}{{ x }}" "{{ empty|first }}"]]
      (is (= :undefined (kind t)) t)))
  (testing "argument evaluation errors win over callee errors"
    (is (= :undefined (kind "{{ nosuch(nosuch2) }}")))
    (is (= :type (kind "{{ n(1/0) }}"))))
  (testing "template"
    (is (= :template (kind "{% include 'nosuch' %}")))
    (is (= :template (kind "{% extends 'nosuch' %}")))
    (is (= :type (kind "{% include 1 %}")))
    (is (= :undefined (kind "{% include nosuch %}"))))
  (testing "type"
    (doseq [t ["{{ 1 + 's' }}" "{{ 's' - 1 }}" "{{ 1 / 0 }}" "{{ 1 // 0 }}" "{{ 1 % 0 }}" "{{ 1 < 's' }}" "{{ 1 in 5 }}" "{{ 5|length }}"
               "{{ n() }}" "{{ 's'|upper(1) }}" "{{ 1|join }}" "{{ [1, 's']|sort }}" "{{ -'a' }}" "{{ [1] < [2] }}" "{{ 0 ** -1 }}"
               "{% for i in 5 %}{% endfor %}" "{{ 1|replace('a') }}" "{{ 5|first }}"]]
      (is (= :type (kind t)) t)))
  (testing "unused broken templates are never loaded"
    (is (= "ok" (render "ok" {"broken" "{% if %}{{ 1|nosuch }}"}))))
  (testing "errors are all-or-nothing"
    (is (thrown? clojure.lang.ExceptionInfo (render "before {{ nosuch }}")))))

(deftest values-and-printing
  (testing "printing of kinds"
    (is (= "True False None" (render "{{ true }} {{ false }} {{ none }}")))
    (is (= "[1, 'a', True, None, 1.5, \"it's\", {'k': [2.0]}]"
           (render "{{ [1, 'a', true, none, 1.5, \"it's\", d2] }}" {} (dict "d2" (dict "k" [2.0])))))
    (is (= "{'a': 1, 'b': 'x'}" (render "{{ d }}")))
    (is (= "['a\\nb\\t\\\\']" (render "{{ ['a\\nb\\t\\\\'] }}"))))
  (testing "floats"
    (is (= ["0.0" "-0.0" "1e-05" "1e+16" "3e+45" "0.0001" "123456789012345.0" "1234567890123456.0"]
           (map #(render (str "{{ " % " }}")) ["0.0" "-0.0" "0.00001" "10000000000000000.0 * 1" "big * 1000000000000000000000000000000.0 * 3" "0.0001" "123456789012345.0" "1234567890123456.0"])))))

(deftest filters
  (is (= "A-B" (render "{{ 'a-b'|upper }}")))
  (is (= "a&amp;b" (render "{{ 'a&b'|escape }}")))
  (is (= "&amp;lt;" (render "{{ '&lt;'|escape }}")) "each character is replaced once")
  (is (= "x" (render "{{ nosuch|default('x') }}")))
  (is (= "" (render "{{ nosuch|default }}")))
  (is (= "0" (render "{{ none|int }}")))
  (is (= "[1, 2, 3]" (render "{{ [3, 1, 2]|sort }}")))
  (is (= "[2, 1.5, True, 1]" (render "{{ [1, true, 2, 1.5]|sort|reverse }}")) "numbers incl. booleans sort numerically, stably")
  (is (= "['a', 'B', 'c']" (render "{{ ['c', 'B', 'a']|sort }}")) "strings sort case-insensitively")
  (is (= "['A', 'a']" (render "{{ ['A', 'a']|sort }}")) "ties keep order")
  (is (= "3" (render "{{ [1, 2, 3]|last }}")))
  (is (= "3" (render "{{ 'abc'|length }}")))
  (is (= "cba" (render "{{ 'abc'|reverse }}")))
  (is (= "a:b" (render "{{ d|join(':') }}")))
  (is (= "ab" (render "{{ ['a', 'b']|join }}")))
  (is (= "1 2 3" (render "{{ [1, 2, 3]|join(' ') }}"))))

(deftest scopes
  (is (= "inner" (render "{% block a %}{% set x = 'inner' %}{{ x }}{% endblock %}")))
  (is (= :undefined (kind "{% for i in [1] %}{% set only = 1 %}{% endfor %}{{ only }}")))
  (is (= "2" (render "{% for i in [1, 2] %}{% if loop.last %}{{ i }}{% endif %}{% endfor %}")))
  (is (= "1" (render "{% macro m() %}{{ outer }}{% endmacro %}{% set outer = 1 %}{{ m() }}"))
      "macros see later sets in their defining scope"))

(deftest environment-caching
  (testing "each template is parsed at most once per environment"
    (let [loads (atom 0)
          env (tpl/make-env (fn [name] (swap! loads inc) (get {"main" "{% include 'x' %}{% include 'x' %}" "x" "x"} name)))]
      (is (= "xx" (tpl/render env "main" {})))
      (is (= "xx" (tpl/render env "main" {})))
      (is (= 2 @loads)))))

;; ---------------------------------------------------------------------------
;; Properties

(defspec integer-arithmetic-agrees-with-clojure 200
  (prop/for-all [a (gen/choose -1000000 1000000) b (gen/choose -1000000 1000000)]
    (and (= (str (+ a b)) (render "{{ a + b }}" {} (dict "a" a "b" b)))
         (= (str (- a b)) (render "{{ a - b }}" {} (dict "a" a "b" b)))
         (= (str (* a b)) (render "{{ a * b }}" {} (dict "a" a "b" b)))
         (or (zero? b)
             (and (= (str (Math/floorDiv (long a) (long b))) (render "{{ a // b }}" {} (dict "a" a "b" b)))
                  (= (str (Math/floorMod (long a) (long b))) (render "{{ a % b }}" {} (dict "a" a "b" b))))))))

(defspec sort-filter-sorts-and-keeps-length 200
  (prop/for-all [xs (gen/vector (gen/choose -50 50) 0 30)]
    (= (str "[" (str/join ", " (sort xs)) "]") (render "{{ xs|sort }}" {} (dict "xs" xs)))))

(defspec join-and-length 200
  (prop/for-all [xs (gen/vector gen/string-alphanumeric 0 10)]
    (and (= (str/join "," xs) (render "{{ xs|join(',') }}" {} (dict "xs" xs)))
         (= (str (count xs)) (render "{{ xs|length }}" {} (dict "xs" xs))))))

(defspec float-printing-round-trips 300
  (prop/for-all [d (gen/double* {:infinite? false :NaN? false})]
    (let [out (render "{{ d }}" {} (dict "d" d))]
      (= d (Double/parseDouble out)))))
