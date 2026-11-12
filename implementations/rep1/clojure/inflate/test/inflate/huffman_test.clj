(ns inflate.huffman-test
  (:require [clojure.test :refer [deftest is testing]]
            [inflate.bits :as bits]
            [inflate.core :as core]
            [inflate.hex :as hex]
            [inflate.huffman :as huff]))

(defn- build [lens root opts]
  (huff/build (int-array lens) 0 (count lens) root opts))

(defn- decode-all
  "Decodes symbols from the hex stream until it throws or `n` symbols are read."
  [table root hex-str n]
  (let [br (bits/reader (hex/decode hex-str))]
    (vec (repeatedly n #(huff/decode br table root)))))

(deftest canonical-codes
  ;; RFC 1951's example: lengths (3 3 3 3 3 2 4 4) give A=010 .. E=110, F=00,
  ;; G=1110, H=1111. Bits are read first-bit-first, so F (00) then A (010)
  ;; is the bit sequence 0,0,0,1,0 -> byte 0b01000 = 0x08.
  (let [table (build [3 3 3 3 3 2 4 4] 3 {})]
    (is (= [5 0] (decode-all table 3 "08" 2)))))

(deftest second-level-tables
  ;; Lengths 1,2,3,...,14,15,15 -> complete code with codes longer than the root.
  (let [lens (vec (concat (range 1 16) [15]))
        table (build lens 4 {})]
    ;; Symbol 15 has code 111111111111111 (15 ones) -> 0x7fff little-endian.
    (is (= [15] (decode-all table 4 "ff7f" 1)))
    ;; Symbol 0 is the single bit 0.
    (is (= [0 0 0] (decode-all table 4 "00" 3)))))

(deftest validity
  (testing "over-subscribed"
    (is (thrown? clojure.lang.ExceptionInfo (build [1 1 1] 3 {}))))
  (testing "incomplete"
    (is (thrown? clojure.lang.ExceptionInfo (build [2 2] 3 {})))
    (is (thrown? clojure.lang.ExceptionInfo (build [1] 3 {})))
    (is (thrown? clojure.lang.ExceptionInfo (build [] 3 {}))))
  (testing "exceptions for incomplete codes"
    (let [t (build [0 1] 3 {:single-ok? true})]
      (is (= [1] (decode-all t 3 "00" 1)))
      (is (thrown? clojure.lang.ExceptionInfo (decode-all t 3 "01" 1))))
    (is (build [] 3 {:empty-ok? true}))
    (is (thrown? clojure.lang.ExceptionInfo (build [2] 3 {:single-ok? true})))))

(deftest errors-are-malformed
  (is (core/malformed? (try (build [1 1 1] 3 {}) (catch Exception e e)))))
