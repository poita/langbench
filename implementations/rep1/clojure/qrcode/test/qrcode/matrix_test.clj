(ns qrcode.matrix-test
  (:require [clojure.test :refer [deftest is testing]]
            [qrcode.mask :as mask]
            [qrcode.matrix :as m]
            [qrcode.tables :as tables])
  (:import (qrcode.matrix Grid)))

(deftest format-information
  ;; ISO/IEC 18004 Annex C: M / mask 0 is the bare XOR mask; L / mask 4
  ;; encodes as 110011000101111.
  (is (= 2r101010000010010 (m/format-bits :m 0)))
  (is (= 2r110011000101111 (m/format-bits :l 4)))
  (is (= 2r000100000111011 (m/format-bits :h 7))))

(deftest version-information
  (is (= 2r000111110010010100 (m/version-bits 7)))
  (is (= 2r101000110001101001 (m/version-bits 40))))

(defn- function-count [^Grid g]
  (count (filter true? (seq (.-function g)))))

(deftest function-module-counts
  ;; Modules not reserved for function patterns are exactly the codeword
  ;; modules, 8*T of them plus the remainder bits.
  (doseq [v (range 1 41)]
    (let [g (m/function-patterns v)
          free (- (* (.-size g) (.-size g)) (function-count g))]
      (testing (str "version " v)
        (is (= (tables/raw-modules v) free))))))

(deftest finder-and-timing-patterns
  (let [g (m/function-patterns 3)]
    (is (m/dark? g 0 0))
    (is (not (m/dark? g 1 1)))
    (is (m/dark? g 3 3))
    (is (not (m/dark? g 7 0)))                       ; separator
    (is (m/dark? g 8 (- (.-size g) 8)) "the always-dark module")
    (is (m/dark? g 8 6) "timing: even index")
    (is (not (m/dark? g 9 6)) "timing: odd index")))

(deftest masks-are-involutions
  (let [g (m/function-patterns 2)
        before (vec (.-modules g))]
    (doseq [k (range 8)]
      (mask/apply-mask! g k)
      (mask/apply-mask! g k))
    (is (= before (vec (.-modules g))))))

(deftest masks-skip-function-modules
  (let [g (m/function-patterns 7)
        before (aclone (.-modules g))]
    (mask/apply-mask! g 0)
    (dotimes [i (alength (.-modules g))]
      (when (aget (.-function g) i)
        (is (= (aget before i) (aget (.-modules g) i)))))))
