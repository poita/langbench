(ns jq.eval-test
  (:require [clojure.test :refer [deftest is testing]]
            [jq.core :as jq]
            [jq.test-util :refer [q q+]]))

(deftest generators-and-order
  (is (= ["[11,12,21,22]"] (q "[(1,2) + (10,20)]" "null")))
  (is (= ["{\"a\":1,\"b\":3}" "{\"a\":1,\"b\":4}" "{\"a\":2,\"b\":3}" "{\"a\":2,\"b\":4}"]
         (q "{a:(1,2), b:(3,4)}" "null")))
  (is (= ["1" "3" "2" "4"] (q "([1,2],[3,4])[(0,1)]" "null")))
  (is (= ["1" "1" "2" "2"] (q "(1, 2) | ., ." "null"))))

(deftest pipes-and-commas
  (is (= ["1" "11" "2" "12"] (q "(1,2) | ., . + 10" "null")))
  (is (= ["[1,2,3]"] (q "[.[]]" "[1,2,3]"))))

(deftest object-key-order
  (is (= ["{\"a\":3,\"b\":2}"] (q "{a:1,b:2,a:3}" "null")))
  (is (= ["{\"z\":9,\"a\":2,\"m\":3}"] (q "{z:1,a:2} + {m:3,z:9}" "null")))
  (is (= ["{\"a\":{\"x\":1,\"y\":2},\"b\":3}"]
         (q ".[0] * .[1]" "[{\"a\":{\"x\":1},\"b\":3},{\"a\":{\"y\":2}}]")))
  (is (= ["[\"a\",\"b\"]"] (q "keys" "{\"b\":1,\"a\":2}"))))

(deftest paths
  (is (= ["null" "null"] (q ".a.b, .a[3]" "{}")))
  (is (= ["3" "null"] (q ".[-1], .[5]" "[1,2,3]")))
  (is (= ["[2,3]" "[1,2]" "[2]"] (q ".[1:], .[:-1], .[1:2]" "[1,2,3]")))
  (is (= ["\"b😀\""] (q ".[1:3]" "\"ab😀c\"")))
  (is (= ["1" "2"] (q ".[]" "{\"x\":1,\"y\":2}"))))

(deftest optional-forms
  (is (= [] (q ".a?" "5")))
  (is (= ["error"] (q+ ".a.b?" "5")))
  (is (= ["[1,3]"] (q "[([1],2,[3])[0]?]" "null")))
  (is (= ["[2]"] (q "[(1,[2],3)[]?]" "null")))
  (is (= ["[1,2]"] (q "[(1,2,error,3)?]" "null")))
  (is (= ["error"] (q+ "(1,2)? | error" "null")))
  (is (= ["[1,2]"] (q "[.[] | tonumber?]" "[\"1\",\"x\",2]")))
  (is (= ["1" "error"] (q+ "(.[] | .a.b?)" "[{\"a\":{\"b\":1}},3]"))))

(deftest try-does-not-catch-downstream-errors
  (is (= ["1" "error"] (q+ "(1,2)? | if . == 2 then error else . end" "null")))
  (is (= ["[1]"] (q "[((1,2) | if . == 2 then error else . end)?]" "null")))
  (is (= ["[1]"] (q "[(((1,2)? | if . == 2 then error else . end), 3)?]" "null"))))

(deftest reduce-and-bindings
  (is (= ["{\"b\":3,\"a\":2}"]
         (q "reduce .[] as $o ({}; . + {($o.k): $o.v})" "[{\"k\":\"b\",\"v\":1},{\"k\":\"a\",\"v\":2},{\"k\":\"b\",\"v\":3}]")))
  (is (= ["null"] (q "reduce (1,2) as $x (0; empty)" "null")))
  (is (= ["2"] (q "reduce (1,2) as $x (0; ., $x)" "null")) "last output wins")
  (is (= ["2"] (q "1 as $x | 2 as $x | $x" "null")))
  (is (= ["[1,10]" "[1,20]"] (q "(1 as $x | (10,20) | [$x, .])" "null")))
  (is (= ["10" "20"] (q ". as $x | (10,20)" "5"))))

(deftest boolean-logic
  (is (= ["false"] (q "false and error" "null")))
  (is (= ["true"] (q "true or error" "null")))
  (is (= ["false" "true" "true"] (q "(true, false) and (true, false) | not" "null")))
  (is (= ["\"b\""] (q "if . then \"a\" else \"b\" end" "null")))
  (is (= ["0"] (q "if . then . end" "0"))))

(deftest errors
  (is (= ["1" "error"] (q+ "1, error, 2" "null")))
  (is (= ["error"] (q+ "[1, error]" "null")))
  (is (= ["error"] (q+ ".[0]" "{}")))
  (is (= ["error"] (q+ ".[null]" "null")))
  (is (= ["error"] (q+ "1 / 0" "null")))
  (is (= ["error"] (q+ "error(null)" "null")))
  (is (= [] (q "error(empty)" "null")))
  (is (= ["error"] (q+ "{(1): 2}" "null")))
  (is (= ["error"] (q+ "-\"a\"" "null"))))

(deftest undefined-things-are-compile-errors
  (is (thrown? clojure.lang.ExceptionInfo (jq/compile-filter "$x")))
  (is (thrown? clojure.lang.ExceptionInfo (jq/compile-filter "nosuchfn"))))

(deftest run-reports-partial-output
  (try (jq/run (jq/compile-filter "1, 2, error") nil)
       (is false "should have thrown")
       (catch clojure.lang.ExceptionInfo e
         (is (jq/error? e))
         (is (= [1.0 2.0] (:outputs (ex-data e)))))))
