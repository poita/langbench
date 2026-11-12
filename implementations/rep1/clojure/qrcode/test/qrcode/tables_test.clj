(ns qrcode.tables-test
  (:require [clojure.test :refer [deftest is testing]]
            [qrcode.tables :as t]))

(deftest data-codeword-examples
  (is (= [19 16 13 9] (map #(t/data-codewords % 1) [:l :m :q :h])))
  (is (= 2956 (t/data-codewords :l 40)))
  (is (= 1276 (t/data-codewords :h 40))))

(deftest total-codewords-known-values
  (is (= 26 (t/total-codewords 1)))
  (is (= 44 (t/total-codewords 2)))
  (is (= 196 (t/total-codewords 7)))
  (is (= 3706 (t/total-codewords 40))))

(deftest every-version-has-consistent-block-structure
  (doseq [v (range 1 41), ecl t/ecls]
    (let [total (t/total-codewords v)
          b (t/block-count ecl v)
          e (t/ecc-codewords-per-block ecl v)]
      (testing (str "v" v " " ecl)
        (is (pos? (t/data-codewords ecl v)))
        (is (< (* b e) total))
        ;; Block lengths differ by at most one codeword.
        (is (= (- total (* b e)) (+ (* b (- (quot total b) e)) (rem total b))))))))

(deftest alignment-positions-shape
  (is (= [] (t/alignment-positions 1)))
  (is (= [6 18] (t/alignment-positions 2)))
  (is (= [6 30 58 86 114 142 170] (t/alignment-positions 40)))
  (doseq [v (range 2 41)]
    ;; Number of positions is v div 7 + 2 and the last one is n - 7.
    (is (= (+ 2 (quot v 7)) (count (t/alignment-positions v))))
    (is (= (- (t/symbol-size v) 7) (peek (t/alignment-positions v))))))

(deftest validation
  (is (thrown? clojure.lang.ExceptionInfo (t/check-version 0)))
  (is (thrown? clojure.lang.ExceptionInfo (t/check-version 41)))
  (is (thrown? clojure.lang.ExceptionInfo (t/check-ecl :x))))
