(ns jq.builtins-test
  (:require [clojure.test :refer [deftest is]]
            [clojure.test.check.clojure-test :refer [defspec]]
            [clojure.test.check.generators :as gen]
            [clojure.test.check.properties :as prop]
            [jq.core :as jq]
            [jq.json :as json]
            [jq.test-util :refer [q q+]]))

(deftest arithmetic
  (is (= ["null" "1" "\"ab\"" "[1,2]" "{\"a\":2}"]
         (q "null + null, null + 1, \"a\" + \"b\", [1] + [2], {a:1} + {a:2}" "null")))
  (is (= ["[1,3]"] (q ". - [2]" "[1,2,3,2]")))
  (is (= ["-1" "1" "1" "-1"] (q "-7 % 3, 7 % -3, 5.5 % 2, -5 % 2" "null")))
  (is (= ["error"] (q+ "5 % 0.5" "null")))
  (is (= ["\"ababab\"" "\"\"" "null" "\"aa\""] (q "\"ab\" * 3, \"ab\" * 0, \"ab\" * -1, 2 * \"a\"" "null")))
  (is (= ["[\"a\",\"b\",\"\",\"c\"]" "[]" "[\"a\",\"b\",\"c\"]"]
         (q "\"a,b,,c\" / \",\", \"\" / \",\", \"abc\" / \"\"" "null")))
  (is (= ["true"] (q "1 == (1.5 - 0.5)" "null")))
  (is (= ["0.75"] (q "3 / 4" "null"))))

(deftest comparison
  (is (= ["true" "true" "false" "true"]
         (q "null < false, false < true, 1 > \"a\", [] < {}" "null"))))

(deftest length-keys-has-type
  (is (= ["0" "3" "2" "3" "2"] (q "(null|length), (-3|length), (\"é😀\"|length), length, ({a:1,b:2}|length)" "[1,2,3]")))
  (is (= ["error"] (q+ "true | length" "null")))
  (is (= ["[0,1]" "[\"a\",\"b\"]"] (q "keys, ({b:1,a:2} | keys)" "[5,6]")))
  (is (= ["true" "false" "true" "false"] (q "has(1), has(-1), has(1.5), (null | has(\"a\"))" "[1,2]")))
  (is (= ["\"null\"" "\"boolean\"" "\"number\"" "\"string\"" "\"array\"" "\"object\""]
         (q "(null,true,1,\"\",[],{}) | type" "null"))))

(deftest add-and-friends
  (is (= ["null" "6" "\"abc\"" "[1,2,3]" "{\"a\":2,\"b\":3}" "3"]
         (q "([]|add), ([1,2,3]|add), ([\"a\",\"b\",\"c\"]|add), ([[1],[2,3]]|add), ([{a:1},{b:3},{a:2}]|add), ({x:1,y:2}|add)" "null")))
  (is (= ["error"] (q+ "[1,\"a\"] | add" "null")))
  (is (= ["[1]"] (q "[null, [1], null] | add" "null"))))

(deftest sorting
  (is (= ["[null,false,true,0,\"a\",[],{}]"]
         (q "sort" "[{},[],\"a\",0,true,false,null]")))
  (is (= ["[{\"k\":\"a\",\"v\":2},{\"k\":\"b\",\"v\":3},{\"k\":\"b\",\"v\":1}]"]
         (q "sort_by(.k, -.v)" "[{\"k\":\"b\",\"v\":1},{\"k\":\"a\",\"v\":2},{\"k\":\"b\",\"v\":3}]")))
  (is (= ["[[{\"a\":1,\"i\":0},{\"a\":1,\"i\":2}],[{\"a\":2,\"i\":1}]]"]
         (q "group_by(.a)" "[{\"a\":1,\"i\":0},{\"a\":2,\"i\":1},{\"a\":1,\"i\":2}]")))
  (is (= ["[1,2,3]" "[\"a\",\"b\"]"] (q "unique, ([\"b\",\"a\",\"b\"]|unique)" "[3,1,2,1]")))
  (is (= ["error"] (q+ "sort" "{}"))))

(deftest min-max-reverse
  (is (= ["1" "3" "null"] (q "min, max, ([]|min)" "[2,1,3]")))
  (is (= ["{\"a\":1,\"b\":2}" "{\"b\":2,\"a\":1}"]
         (q "min, max" "[{\"a\":1,\"b\":2},{\"b\":2,\"a\":1}]")))
  (is (= ["[3,2,1]" "[]"] (q "reverse, (null | reverse)" "[1,2,3]")))
  (is (= ["error"] (q+ "\"abc\" | reverse" "null"))))

(deftest tostring-tonumber
  (is (= ["\"abc\"" "\"[1,{\\\"a\\\":null}]\"" "12" "-2.5"]
         (q "(\"abc\"|tostring), ([1,{a:null}]|tostring), (\"12\"|tonumber), (\"-2.5\"|tonumber)" "null")))
  (is (= ["error"] (q+ "\"abc\" | tonumber" "null")))
  (is (= ["error"] (q+ "\"\" | tonumber" "null"))))

(deftest select-map
  (is (= ["[2,3]"] (q "map(select(. > 1))" "[1,2,3]")))
  (is (= ["[2,4]"] (q "map(. * 2)" "{\"a\":1,\"b\":2}")))
  (is (= ["[1,1,2,2]"] (q "map(., .)" "[1,2]")))
  (is (= ["error"] (q+ "map(.)" "null"))))

(defspec sort-is-sorted-and-stable 100
  (prop/for-all [xs (gen/vector (gen/tuple (gen/choose 0 4) gen/small-integer) 0 40)]
    (let [doc (json/stringify (mapv (fn [[k i]] (json/parse (str "{\"k\":" k ",\"i\":" i "}"))) xs))
          out (json/parse (first (q "sort_by(.k)" doc)))
          pairs (mapv (fn [o] [(long (get o "k")) (long (get o "i"))]) out)]
      (= pairs (vec (sort-by first xs))))))

(defspec unique-is-idempotent 100
  (prop/for-all [xs (gen/vector gen/small-integer 0 40)]
    (let [doc (json/stringify (mapv double xs))
          u (first (q "unique" doc))]
      (and (= u (first (q "unique" u)))
           (= (json/stringify (mapv double (sort (distinct xs)))) u)))))
