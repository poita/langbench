(ns protowire.text-test
  (:require [clojure.test :refer [deftest is testing]]
            [protowire.core :as pw]
            [protowire.test-util :refer [all-types-schema error? example-schema]]))

(defn- fmt [m] (pw/format-text all-types-schema "Node" m))
(defn- parse [s] (pw/parse-text all-types-schema "Node" s))
(defn- bad? [s] (error? #(parse s)))

(deftest printing
  (is (= "{}" (fmt {})))
  (is (= "{}" (fmt {:i32 0 :s "" :b false :ri32 []})) "defaults and empty lists vanish")
  (is (= "{i32: -5, b: true, child: {}}" (fmt {:child {} :b true :i32 -5}))
      "number order; empty sub-message printed")
  (is (= "{ri32: [0, 1], rb: [true, false], rs: [\"\"], ry: [x\"\"]}"
         (fmt {:ry [(byte-array 0)] :rs [""] :rb [true false] :ri32 [0 1]})))
  (is (= "{u64: 18446744073709551615}" (fmt {:u64 18446744073709551615N}))))

(deftest string-escaping
  (is (= "{s: \"\\\"\\\\\\n\\r\\t\\x00\\x1f\\x7f é\"}"
         (fmt {:s "\"\\\n\r\t\u0000\u001f\u007f é"})))
  (is (= {:s "\"\t\\"} (parse "{s: \"\\\"\\t\\\\\"}")))
  (is (= {:s "é"} (parse "{s: \"\\xc3\\xa9\"}")))
  (is (= {:s "é"} (parse "{s: \"\\xC3\\xA9\"}")))
  (is (= {:s "\u007f"} (parse "{s: \"\u007f\"}")))
  (is (bad? "{s: \"\\xc3\"}") "invalid UTF-8 after unescaping")
  (is (bad? "{s: \"\\q\"}"))
  (is (bad? "{s: \"\t\"}"))
  (is (bad? "{s: \"abc}")))

(deftest relaxed-parsing
  (is (= {:i32 1 :ri32 [1 2]} (parse "{i32:1,ri32:[1,2]}")))
  (is (= {:i32 1} (parse "  {  i32  :  1  }  ")))
  (is (= {:ri32 [] :s "" :b false :i32 0 :child {}}
         (parse "{child: {}, b: false, s: \"\", ri32: [], i32: 0}")))
  (is (= [1 2] (:ri32 (parse "{ ri32 : [ 1 , 2 ] }"))))
  (is (= [0 255] (map #(bit-and % 255) (:y (parse "{y: x\"00ff\"}"))))))

(deftest rejected-text
  (doseq [s ["" " " "{" "}" "{} x" "{i32: 1,}" "{,}" "{i32: 1 i32: 2}"
             "{i32: 1, i32: 1}" "{nope: 1}" "{i32: - 1}" "{i32: -0}" "{i32: 007}"
             "{i32: +5}" "{i32: 1.0}" "{i32: \"1\"}" "{i32: [1]}" "{ri32: 1}"
             "{ri32: [1,]}" "{ri32: [[1]]}" "{b: 1}" "{b: True}" "{b: tr ue}"
             "{y: x \"00\"}" "{y: x\"0\"}" "{y: x\"AB\"}" "{y: x\"zz\"}"
             "{s: 5}" "{child: 5}" "{i32: {}}" "{i32: 2147483648}"
             "{u32: -1}" "{u64: 18446744073709551616}" "{i32: 1}\t"
             "{\ti32: 1}" "{i32 1}" "{i32: 1; }"]]
    (is (bad? s) (pr-str s)))
  (testing "extremes are accepted"
    (is (= {:i64 Long/MIN_VALUE} (parse "{i64: -9223372036854775808}")))
    (is (= {:u64 18446744073709551615N} (parse "{u64: 18446744073709551615}")))))
