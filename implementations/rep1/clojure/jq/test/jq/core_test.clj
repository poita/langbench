(ns jq.core-test
  "Evaluation semantics, mostly written as (filter, input JSON) -> output JSON
  lines, following SPEC.md."
  (:require [clojure.test :refer [deftest is testing are]]
            [jq.core :as jq]
            [jq.json :as json]
            [jq.value :as v]))

(defn q
  "Outputs of `filter` on the JSON text `in`, as compact JSON strings."
  [filter in]
  (jq/query-string filter in))

(defn- error-results
  "If `filter` errors on `in`, the JSON outputs produced before the error."
  [filter in]
  (try (q filter in) nil
       (catch clojure.lang.ExceptionInfo e
         (when (jq/error? e) (mapv json/stringify (:results (ex-data e)))))))

(deftest paths
  (are [f in out] (= out (q f in))
    "."            "{\"b\":1,\"a\":2}" ["{\"b\":1,\"a\":2}"]
    ".a"           "{\"a\":1}" ["1"]
    ".a"           "{}" ["null"]
    ".a"           "null" ["null"]
    ".\"a b\""     "{\"a b\":3}" ["3"]
    ".[0], .[-1], .[5]" "[1,2,3]" ["1" "3" "null"]
    ".[\"a\"]"     "{\"a\":1}" ["1"]
    ".[]"          "[1,[2]]" ["1" "[2]"]
    ".[]"          "{\"b\":1,\"a\":2}" ["1" "2"]
    ".[1:3]"       "[1,2,3,4]" ["[2,3]"]
    ".[:-1]"       "[1,2,3]" ["[1,2]"]
    ".[2:]"        "\"héllo\"" ["\"llo\""]
    ".[3:1]"       "[1,2,3]" ["[]"]
    ".[1:]"        "null" ["null"]
    "([1,2],[3,4])[(0,1)]" "null" ["1" "3" "2" "4"]))

(deftest path-errors
  (are [f in] (= [] (error-results f in))
    ".a"   "5"
    ".[0]" "{\"a\":1}"
    ".[]"  "null"
    ".[null]" "null"
    ".[1:2]" "5"))

(deftest optional
  (are [f in out] (= out (q f in))
    ".a?"                 "5" []
    "[.[] | .a?]"         "[{\"a\":1},5]" ["[1]"]
    "[([1],2,[3])[0]?]"   "null" ["[1,3]"]
    "[(1,[2],3)[]?]"      "null" ["[2]"]
    "[(1,2,error,3)?]"    "null" ["[1,2]"]
    "(.a.b)?"             "5" []
    "[.[] | tonumber?]"   "[\"1\",\"x\",\"2.5\"]" ["[1,2.5]"]
    "[.[1:]?]"            "5" ["[]"])
  (is (= [] (error-results ".a.b?" "5")))
  (is (= [] (error-results "(1,2)? | error" "null")))
  (is (= ["1"] (error-results ".[] | .a.b?" "[{\"a\":{\"b\":1}},3]"))))

(deftest arithmetic
  (are [f out] (= out (q f "null"))
    "1 + 2"                    ["3"]
    "null + 1, 1 + null"       ["1" "1"]
    "\"a\" + \"b\""            ["\"ab\""]
    "[1] + [2]"                ["[1,2]"]
    "{\"z\":1,\"a\":2} + {\"m\":3,\"z\":9}" ["{\"z\":9,\"a\":2,\"m\":3}"]
    "{\"a\":{\"x\":1}} * {\"a\":{\"y\":2},\"b\":1}" ["{\"a\":{\"x\":1,\"y\":2},\"b\":1}"]
    "[1,2,3,2] - [2]"          ["[1,3]"]
    "\"ab\" * 3, 2 * \"x\", \"x\" * 0, \"x\" * -1" ["\"ababab\"" "\"xx\"" "\"\"" "null"]
    "7 / 2"                    ["3.5"]
    "\"a,b,,c\" / \",\""       ["[\"a\",\"b\",\"\",\"c\"]"]
    "\"\" / \",\""             ["[]"]
    "\"abc\" / \"\""           ["[\"a\",\"b\",\"c\"]"]
    "-7 % 3, 7 % -3, 5.5 % 2"  ["-1" "1" "1"]
    "[(1,2) + (10,20)]"        ["[11,12,21,22]"]
    "1 - -1, 2 * -3"           ["2" "-6"]
    "-(1 + 2)"                 ["-3"]))

(deftest arithmetic-errors
  (are [f] (= [] (error-results f "null"))
    "1 / 0" "5 % 0.5" "\"a\" - 1" "{} - {}" "[] * 2" "1 + \"a\"" "-\"a\"" "{} + 1"))

(deftest comparison-and-logic
  (are [f out] (= out (q f "null"))
    "1 == 1.0000, 1 == (1.5 - 0.5)" ["true" "true"]
    "[1,2] < [1,3], \"a\" < \"b\", null < false, {} > []" ["true" "true" "true" "true"]
    "false and error"            ["false"]
    "true or error"              ["true"]
    "(true, false) and (true, false)" ["true" "false" "false"]
    "null or 0"                  ["true"]
    "if 0 then 1 else 2 end"     ["1"]
    "if null then 1 elif false then 2 else 3 end" ["3"]
    "if false then 1 end"        ["null"]
    "[if (true,false) then 1 else 2 end]" ["[1,2]"]))

(deftest generators-and-construction
  (are [f out] (= out (q f "{\"a\":1}"))
    "{a:(1,2), b:(3,4)}" ["{\"a\":1,\"b\":3}" "{\"a\":1,\"b\":4}" "{\"a\":2,\"b\":3}" "{\"a\":2,\"b\":4}"]
    "{a:1,b:2,a:3}"      ["{\"a\":3,\"b\":2}"]
    "{a}, {\"a\"}"       ["{\"a\":1}" "{\"a\":1}"]
    "1 as $x | {$x}"     ["{\"x\":1}"]
    "{(\"k\" + \"1\"): 2}" ["{\"k1\":2}"]
    "{a: .a | tostring}" ["{\"a\":\"1\"}"]
    "[]"                 ["[]"]
    "[empty]"            ["[]"]
    "[.a, 2]"            ["[1,2]"]
    "1, 2 | . * 10"      ["10" "20"])
  (is (= [] (error-results "{(1): 2}" "null"))))

(deftest variables-and-reduce
  (are [f out] (= out (q f "[1,2,3]"))
    ".[] as $x | $x * 2"                      ["2" "4" "6"]
    "1 as $x | 2 as $x | $x"                  ["2"]
    "(1,2) as $x | (3,4) as $y | [$x,$y]"     ["[1,3]" "[1,4]" "[2,3]" "[2,4]"]
    "reduce .[] as $i (0; . + $i)"            ["6"]
    "reduce .[] as $i ([]; [$i] + .)"         ["[3,2,1]"]
    "reduce empty as $i (5; . + 1)"           ["5"]
    "reduce .[] as $i (0; empty)"             ["null"]
    "reduce .[] as $i (0, 10; . + $i)"        ["6" "16"]))

(deftest builtins
  (are [f in out] (= out (q f in))
    "length"  "\"😀é\"" ["2"]
    "length"  "-2.5" ["2.5"]
    "length"  "null" ["0"]
    "length"  "{\"a\":1}" ["1"]
    "keys"    "{\"b\":1,\"a\":2}" ["[\"a\",\"b\"]"]
    "keys"    "[5,6]" ["[0,1]"]
    "[has(\"a\"), has(\"z\")]" "{\"a\":1}" ["[true,false]"]
    "[has(0), has(1.5), has(-1), has(2)]" "[1,2]" ["[true,true,false,false]"]
    "has(\"a\")" "null" ["false"]
    "type"    "[]" ["\"array\""]
    "[.[] | type]" "[null,true,1,\"s\",[],{}]" ["[\"null\",\"boolean\",\"number\",\"string\",\"array\",\"object\"]"]
    "add"     "[1,2,3]" ["6"]
    "add"     "[]" ["null"]
    "add"     "[\"a\",\"b\"]" ["\"ab\""]
    "add"     "[[1],[2]]" ["[1,2]"]
    "add"     "{\"a\":1,\"b\":2}" ["3"]
    "add"     "[null,1]" ["1"]
    "map(. + 1)" "[1,2]" ["[2,3]"]
    "map(.)"  "{\"a\":1}" ["[1]"]
    "map(select(. > 1))" "[1,2,3]" ["[2,3]"]
    "sort"    "[3,\"a\",null,1,[0],true]" ["[null,true,1,3,\"a\",[0]]"]
    "sort_by(.a, .b)" "[{\"a\":2,\"b\":1},{\"a\":1,\"b\":2},{\"a\":1,\"b\":1}]"
    ["[{\"a\":1,\"b\":1},{\"a\":1,\"b\":2},{\"a\":2,\"b\":1}]"]
    "sort_by(.k)" "[{\"k\":1,\"i\":1},{\"k\":0,\"i\":2},{\"k\":1,\"i\":3}]"
    ["[{\"k\":0,\"i\":2},{\"k\":1,\"i\":1},{\"k\":1,\"i\":3}]"]
    "group_by(.k)" "[{\"k\":1},{\"k\":0},{\"k\":1,\"x\":1}]"
    ["[[{\"k\":0}],[{\"k\":1},{\"k\":1,\"x\":1}]]"]
    "group_by(.)" "[]" ["[]"]
    "unique"  "[3,1,3,2,1]" ["[1,2,3]"]
    "reverse" "[1,2,3]" ["[3,2,1]"]
    "reverse" "null" ["[]"]
    "min, max" "[2,1,3]" ["1" "3"]
    "min, max" "[]" ["null" "null"]
    "max"     "[{\"a\":1,\"b\":2},{\"b\":2,\"a\":1}]" ["{\"b\":2,\"a\":1}"]
    "min"     "[{\"a\":1,\"b\":2},{\"b\":2,\"a\":1}]" ["{\"a\":1,\"b\":2}"]
    "tostring" "\"x\"" ["\"x\""]
    "tostring" "{\"a\":[1,2.5,null]}" ["\"{\\\"a\\\":[1,2.5,null]}\""]
    "tonumber" "\"-2.5\"" ["-2.5"]
    "tonumber" "7" ["7"]
    "[.[] | not]" "[null,false,0,true]" ["[true,true,false,false]"]
    "empty"   "1" []
    "select(. > 1)" "1" []
    "select(. > 1)" "2" ["2"]))

(deftest builtin-errors
  (are [f in] (= [] (error-results f in))
    "length" "true" "keys" "1" "has(0)" "{}" "tonumber" "\"abc\"" "tonumber" "\"\""
    "tonumber" "[]" "reverse" "\"abc\"" "sort" "{}" "map(.)" "null" "add" "null"
    "min" "{}" "error" "null" "error(null)" "1" "sort_by(.)" "1"))

(deftest error-builtin
  (is (= [] (q "error(empty)" "1")))
  (is (= ["1"] (error-results "1, error, 2" "null")))
  (is (thrown? clojure.lang.ExceptionInfo (jq/compile "frobnicate"))))

(deftest results-before-error
  (is (= ["1" "2"] (error-results ".[] | if . > 2 then error else . end" "[1,2,3,4]"))))

(deftest library-api
  (let [f (jq/compile ".a | map(. * 2)")]
    (is (= [[2.0 4.0]] (jq/run f (v/from-clj {"a" [1 2]}))))
    (is (= [[2.0 4.0]] (jq/run f (json/parse "{\"a\":[1,2]}")))))
  (is (= [1.0 2.0] (jq/run (jq/compile "$x, $y") nil {"x" 1.0 "y" 2.0})))
  (let [acc (atom [])]
    (is (thrown? clojure.lang.ExceptionInfo
                 (jq/run-each (jq/compile "1, error, 2") nil #(swap! acc conj %))))
    (is (= [1.0] @acc)))
  (is (thrown? clojure.lang.ExceptionInfo (jq/compile "1 +"))))
