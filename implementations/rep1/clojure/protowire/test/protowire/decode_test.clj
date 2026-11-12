(ns protowire.decode-test
  (:require [clojure.test :refer [deftest is testing]]
            [protowire.core :as pw]
            [protowire.test-util :refer [all-types-schema error? example-schema]]))

(defn- dec* [schema msg hex] (pw/decode-hex schema msg hex))
(defn- err? [schema msg hex] (error? #(dec* schema msg hex)))

(deftest basic-decoding
  (is (= {:a 1 :b "x" :c [1 2] :d {:v -5}}
         (dec* example-schema "Outer" "08011201781a02010222020809")))
  (is (= {} (dec* example-schema "Outer" "")))
  (is (= {:d {}} (dec* example-schema "Outer" "2200")) "empty sub-message is present"))

(deftest scalar-conversion
  (let [d #(dec* all-types-schema "Node" %)]
    (is (= {:i32 -1} (d "08ffffffffffffffffff01")))
    (is (= {:i32 5} (d "08858080808010")) "int32 keeps the low 32 bits")
    (is (= {:u64 18446744073709551615N} (d "20ffffffffffffffffff01")))
    (is (= {:s32 -1} (d "2801")))
    (is (= {:s64 Long/MIN_VALUE} (d "30ffffffffffffffffff01")))
    (is (= {:b true} (d "3802")))
    (is (= {:f32 4294967295} (d "45ffffffff")))
    (is (= {:sf32 -1} (d "4dffffffff")))
    (is (= {:sf64 -1} (d "59ffffffffffffffff")))
    (is (= {:f64 18446744073709551615N} (d "51ffffffffffffffff")))))

(deftest strings-and-bytes
  (let [d #(dec* all-types-schema "Node" %)]
    (is (= {:s "é\u0000"} (d "6203c3a900")))
    (is (= {:s "😀"} (d "6204f09f9880")))
    (is (err? all-types-schema "Node" "6201ff"))
    (is (err? all-types-schema "Node" "6203eda080") "surrogate")
    (is (err? all-types-schema "Node" "6202c080") "overlong")
    (is (= [0 -1] (seq (:y (d "6a0200ff")))))))

(deftest repeated-fields
  (let [d #(dec* all-types-schema "Node" %)]
    (testing "packed, unpacked and mixed"
      (is (= {:ri32 [1 2]} (d "7a020102")))
      (is (= {:ri32 [1 2]} (d "78017802")))
      (is (= {:ri32 [1 2 3 4]} (d "78017a0202037804"))))
    (testing "empty packed payload contributes nothing"
      (is (= {} (d "7a00"))))
    (testing "packed fixed payloads must be a multiple of the element size"
      (is (err? all-types-schema "Node" "9a0103000000"))
      (is (= {:rf32 [1]} (d "9a010401000000")))
      (is (err? all-types-schema "Node" "a201050000000000")))
    (testing "packed varint cut in the middle of an element"
      (is (err? all-types-schema "Node" "7a0180")))
    (testing "repeated strings and messages are never packed"
      (is (= {:rs ["a" "b"]} (d "aa010161aa010162")))
      (is (= {:rn [{:i32 1} {}]} (d "ba01020801ba0100"))))))

(deftest merging
  (is (= {:child {:i32 1 :ri32 [1 2] :b true}}
         (dec* all-types-schema "Node" "720408017801720438017802")))
  (is (= {:i32 2} (dec* all-types-schema "Node" "08010802")) "last scalar wins"))

(deftest skipping
  (testing "wrong wire type is skipped, not an error"
    (is (= {} (dec* example-schema "Outer" "0d00000000")))
    (is (= {:a 7} (dec* example-schema "Outer" "0d000000000807"))))
  (testing "groups"
    (is (= {:c [5]} (dec* example-schema "Outer" "1b08011c1805")))
    (is (= {:c [5]} (dec* example-schema "Outer" "1b23241c1805")))
    (is (err? example-schema "Outer" "1b0814"))
    (is (err? example-schema "Outer" "1b0801"))
    (is (err? example-schema "Outer" "1c")))
  (testing "unknown length-delimited payload is not inspected"
    (is (= {} (dec* example-schema "Outer" "3a02ffff")))))

(deftest invalid-input
  (is (err? example-schema "Outer" "08ff"))
  (is (err? example-schema "Outer" "0800 "))
  (is (err? example-schema "Outer" "00"))
  (is (err? example-schema "Outer" "0e"))
  (is (err? example-schema "Outer" "0f"))
  (is (err? example-schema "Outer" "1201"))
  (is (err? example-schema "Outer" "ABC"))
  (is (err? example-schema "Outer" "080"))
  (is (err? example-schema "Outer" "808080808010")))
