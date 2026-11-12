(ns json.core-test
  (:require [clojure.test :refer [deftest is testing]]
            [clojure.test.check.clojure-test :refer [defspec]]
            [clojure.test.check.properties :as prop]
            [json.core :as json]
            [json.generators :as g]
            [json.tree :as tree])
  (:import (java.io ByteArrayInputStream)
           (java.nio.charset StandardCharsets)))

(deftest spec-examples
  (is (= "{\"a\":\"héllo/\",\"b\":null}"
         (json/canonicalize "{ \"b\": [1, 2.50, 1E+3], \"a\": \"héllo\\/\", \"b\": null }")))
  (is (= "[\"😀\",-0,1e-7,0.0,1e0,\"tab\\tquote\\\"nul\\u0000 AA\"]"
         (json/canonicalize
          "[\"😀\", -0, 1e-007, 0.0, 1e-0, \"tab\\tquote\\\"nul\\u0000 A\\u0041\"]")))
  (is (= [0x22 0x7f 0x2f 0xe2 0x80 0xa8 0xf0 0x9f 0x98 0x80 0x22]
         (map #(bit-and % 0xFF)
              (json/canonicalize-bytes "\"\\u007f\\/\\u2028\\uD83D\\uDE00\""))))
  (is (= "{\"Z\":4,\"😀\":2,\"\uE000\":1,\"\uFFFF\":3}"
         (json/canonicalize "{\"\\uE000\":1,\"😀\":2,\"\\uFFFF\":3,\"Z\":4}"))))

(deftest input-kinds
  (let [s "[1, 2]"]
    (is (= "[1,2]" (json/canonicalize s)))
    (is (= "[1,2]" (json/canonicalize (.getBytes s StandardCharsets/UTF_8))))
    (is (= "[1,2]" (json/canonicalize (ByteArrayInputStream. (.getBytes s StandardCharsets/UTF_8)))))
    (is (thrown? IllegalArgumentException (json/parse 42)))))

(deftest validity
  (is (json/valid? "{}"))
  (is (not (json/valid? "[1,]")))
  (is (not (json/valid? (byte-array [0xFF]))))
  (is (thrown? Exception (json/parse "[1,]")))
  (is (json/invalid? (try (json/parse "[1,]") (catch Exception e e)))))

(deftest tree-api
  (let [t (json/parse "{\"a\":[1.0e+2,true]}")]
    (is (json/obj-node? t))
    (is (= "a" (key (first (json/members t)))))
    (let [arr (val (first (json/members t)))]
      (is (json/num-node? (first arr)))
      (is (= "1.0e2" (json/number-text (first arr)))))
    (is (= "{\"k\":null}" (json/serialize (json/obj-node [["k" nil]]))))))

(defspec canonical-form-is-stable 300
  (prop/for-all [t g/json-tree]
    (let [once (json/canonicalize (json/serialize t))]
      (= once (json/canonicalize once)))))

(defspec serialized-trees-are-valid 300
  (prop/for-all [t g/json-tree]
    (json/valid? (json/serialize t))))

(defspec strings-round-trip 300
  (prop/for-all [s g/json-string]
    (= s (json/parse (json/serialize s)))))

(defspec number-text-is-normalized 300
  (prop/for-all [lexeme g/number-lexeme]
    (let [out (json/number-text (json/parse lexeme))]
      (and (re-matches #"-?(0|[1-9][0-9]*)(\.[0-9]+)?(e-?(0|[1-9][0-9]*))?" out)
           (not (re-find #"e-0$" out))))))

(defn- utf16-key [^String s] (mapv int (.toCharArray s)))

(defn- lex-compare
  "Lexicographic comparison of two int sequences; a proper prefix sorts first."
  [a b]
  (loop [a (seq a) b (seq b)]
    (cond (and (nil? a) (nil? b)) 0
          (nil? a) -1
          (nil? b) 1
          :else (let [c (compare (first a) (first b))]
                  (if (zero? c) (recur (next a) (next b)) c)))))

(defspec object-members-sorted-and-last-wins 300
  (prop/for-all [members (clojure.test.check.generators/vector
                          (clojure.test.check.generators/tuple
                           g/json-string
                           (clojure.test.check.generators/fmap (comp tree/num-node str) clojure.test.check.generators/nat))
                          0 12)]
    (let [out      (json/parse (json/serialize (tree/obj-node members)))
          got      (map vec (tree/members out))
          expected (->> members
                        (reduce (fn [m [k v]] (assoc m k v)) {})
                        (sort-by (comp utf16-key key) lex-compare)
                        (map vec))]
      (= expected got))))
