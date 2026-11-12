(ns template.main-test
  (:require [clojure.test :refer [deftest is]]
            [template.input :as input]
            [template.main :as main]))

(deftest input-splitting
  (let [{:keys [context main templates]}
        (input/parse-input "{\n \"a\": 1\n}\n--\n=== first\nbody1\n\n=== second/x-y.z\nbody2\n")]
    (is (= "{'a': 1}" (template.values/to-str context)))
    (is (= "first" main))
    (is (= {"first" "body1\n" "second/x-y.z" "body2"} templates))))

(deftest process-success
  (is (= "Hello ADA!\n" (main/process "{\"name\": \"ada\"}\n--\n=== main\nHello {{ name|upper }}!")))
  (is (= "\n" (main/process "{}\n--\n=== main\n")))
  (is (= "a\n\n" (main/process "{}\n--\n=== main\na\n\n"))))

(deftest process-errors
  (is (= "error: syntax\n" (main/process "{}\n--\n=== main\n{% if %}")))
  (is (= "error: undefined\n" (main/process "{\"a\": {\"b\": 1}}\n--\n=== main\nbefore {{ a.b }}{{ a.c.d }}")))
  (is (= "error: template\n" (main/process "{}\n--\n=== main\n{% include 'x' %}")))
  (is (= "error: filter\n" (main/process "{}\n--\n=== main\n{{ 1|zzz }}")))
  (is (= "error: type\n" (main/process "{}\n--\n=== main\n{{ 1 + 'a' }}"))))

(deftest spec-example
  (is (= "<h1>T</h1>\n3 items<ul><li>#1</li><li>#2</li><li>#3</li></ul>\n-- t end\n"
         (main/process
          (str "{\"title\": \"T\", \"items\": [3, 1, 2]}\n--\n=== page\n{% extends \"base\" %}\n"
               "{% set count = items|length %}\n"
               "{% block body %}{{ super() }}<ul>{% for i in items|sort %}<li>{{ item(i) }}</li>{% endfor %}</ul>{% endblock %}\n"
               "=== base\n{% macro item(v) %}#{{ v }}{% endmacro -%}\n"
               "<h1>{% block title %}{{ title }}{% endblock %}</h1>\n"
               "{% block body %}{{ count }} items{% endblock %}\n{% include \"footer\" %}\n"
               "=== footer\n-- {{ title|lower }} {{ missing|default(\"end\") }}")))))
