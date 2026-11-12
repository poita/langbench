(ns kvstore.value-test
  (:require [clojure.test :refer [deftest is testing]]
            [clojure.test.check.clojure-test :refer [defspec]]
            [clojure.test.check.generators :as gen]
            [clojure.test.check.properties :as prop]
            [kvstore.bytes :as b]
            [kvstore.value :as v]))

(def gen-value
  (gen/recursive-gen
   (fn [inner]
     (gen/one-of [(gen/vector inner 0 4)
                  (gen/map gen/string inner {:max-elements 4})]))
   (gen/one-of [(gen/return nil) gen/boolean gen/large-integer gen/string])))

(deftest serialisation-examples
  (testing "worked serialisations of spec section 4.2"
    (is (= "030000000000000001" (b/hex (v/ser 1))))
    (is (= "03ffffffffffffffff" (b/hex (v/ser -1))))
    (is (= "00" (b/hex (v/ser nil))))
    (is (= "02" (b/hex (v/ser true))))
    (is (= "0400000000" (b/hex (v/ser ""))))
    (is (= "0400000003616461" (b/hex (v/ser "ada")) ))
    (is (= 21 (alength (v/ser [1 "x" nil]))))
    (is (= 44 (alength (v/ser {"name" "ada" "age" 36 "ok" true}))))))

(deftest object-fields-are-sorted
  (is (= (b/hex (v/ser {"b" 1 "a" 2})) (b/hex (v/ser (array-map "a" 2 "b" 1)))))
  (is (= "{\"age\":36,\"name\":\"ada\"}" (v/render {"name" "ada" "age" 36}))))

(deftest rendering
  (is (= "null" (v/render nil)))
  (is (= "-9223372036854775808" (v/render Long/MIN_VALUE)))
  (is (= "[1,\"x\",null]" (v/render [1 "x" nil])))
  (is (= "{}" (v/render {})))
  (is (= "\"a\\\"b\"" (v/render "a\"b")))
  (testing "escapes"
    (is (= "\"\\u0000\\u001f\\u007f\\b\\t\\n\\f\\r\\\\/é😀\""
           (v/render "\u0000\u001f\u007f\b\t\n\f\r\\/é😀")))))

(deftest depth-counts-levels
  (is (= 1 (v/depth 1)))
  (is (= 1 (v/depth [])))
  (is (= 3 (v/depth {"a" [1]}))))

(deftest paths
  (let [doc {"a" {"b" 1} "l" [1]}]
    (is (= 1 (v/resolve-path doc ["a" "b"])))
    (is (identical? v/missing (v/resolve-path doc ["l" "0"])))
    (is (= {"a" {"b" 1 "c" 2} "l" [1]} (v/assoc-path doc ["a" "c"] 2)))
    (is (= {"a" {"x" {"y" 1}}} (v/assoc-path {} ["a" "x" "y"] 1)))
    (is (= :not-object (try (v/assoc-path doc ["a" "b" "c"] 1) (catch Exception e (:kind (ex-data e))))))
    (is (= :no-field (try (v/dissoc-path doc ["a" "z"]) (catch Exception e (:kind (ex-data e))))))
    (is (= {"a" {} "l" [1]} (v/dissoc-path doc ["a" "b"])))))

(defspec serialisation-round-trips 200
  (prop/for-all [x gen-value]
    (= x (v/deser (v/ser x)))))
