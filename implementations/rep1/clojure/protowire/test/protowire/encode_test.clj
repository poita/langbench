(ns protowire.encode-test
  (:require [clojure.test :refer [deftest is testing]]
            [protowire.core :as pw]
            [protowire.test-util :refer [all-types-schema error? example-schema]]))

(defn- enc [schema msg m] (pw/encode-hex schema msg m))
(defn- err? [schema msg m] (error? #(enc schema msg m)))

(deftest canonical-encoding
  (is (= "08011201781a02010222020809"
         (enc example-schema "Outer" {:d {:v -5} :c [1 2] :b "x" :a 1}))
      "fields come out in field-number order")
  (is (= "" (enc example-schema "Outer" {})))
  (is (= "2200" (enc example-schema "Outer" {:d {} :c [] :a 0 :b ""}))
      "defaults vanish but an empty sub-message stays")
  (is (= "1a03000000" (enc example-schema "Outer" {:c [0 0 0]}))
      "default elements of a repeated field are kept"))

(deftest scalar-encoding
  (let [e #(enc all-types-schema "Node" %)]
    (is (= "08ffffffffffffffffff01" (e {:i32 -1})))
    (is (= "10ffffffffffffffffff01" (e {:i64 -1})))
    (is (= "20ffffffffffffffffff01" (e {:u64 18446744073709551615N})))
    (is (= "20ffffffffffffffffff01" (e {:u64 (bigint 18446744073709551615N)})))
    (is (= "28ffffffff0f" (e {:s32 Integer/MIN_VALUE})))
    (is (= "30ffffffffffffffffff01" (e {:s64 Long/MIN_VALUE})))
    (is (= "3801" (e {:b true})))
    (is (= "" (e {:b false})))
    (is (= "45ffffffff" (e {:f32 4294967295})))
    (is (= "4dffffffff" (e {:sf32 -1})))
    (is (= "59ffffffffffffffff" (e {:sf64 -1})))
    (is (= "6203c3a900" (e {:s "é\u0000"})))
    (is (= "6a0200ff" (e {:y (byte-array [0 -1])})))))

(deftest repeated-encoding
  (let [e #(enc all-types-schema "Node" %)]
    (is (= "7a020102" (e {:ri32 [1 2]})) "numeric fields are packed")
    (is (= "7a0d010203ffffffffffffffffff01" (e {:ri32 [1 2 3 -1]})) "negative int32 is ten bytes")
    (is (= "9a010801000000ffffffff" (e {:rf32 [1 4294967295]})))
    (is (= "aa010161aa010162" (e {:rs ["a" "b"]})))
    (is (= "ba01020801ba0100" (e {:rn [{:i32 1} {}]})))
    (is (= "" (e {:rs []})))))

(deftest nested-size-prefixes
  (testing "lengths larger than one varint byte"
    (let [s (apply str (repeat 300 "a"))
          out (enc all-types-schema "Node" {:child {:child {:s s}}})]
      ;; innermost: 62 ac02 + 300 bytes = 303 (af02); middle: 72 af02 + 303 = 306 (b202)
      (is (= (* 2 (+ 3 306)) (count out)))
      (is (.startsWith ^String out "72b20272af0262ac02")))))

(deftest invalid-values
  (is (err? example-schema "Outer" {:a 2147483648}))
  (is (err? example-schema "Outer" {:a -2147483649}))
  (is (err? example-schema "Outer" {:a "1"}))
  (is (err? example-schema "Outer" {:a 1.0}))
  (is (err? example-schema "Outer" {:b 5}))
  (is (err? example-schema "Outer" {:c 5}))
  (is (err? example-schema "Outer" {:d 5}))
  (is (err? example-schema "Outer" {:nope 1}))
  (is (err? all-types-schema "Node" {:u32 -1}))
  (is (err? all-types-schema "Node" {:u64 18446744073709551616N}))
  (is (err? all-types-schema "Node" {:b 1}))
  (is (err? all-types-schema "Node" {:s "\ud800"}) "not encodable as UTF-8"))
