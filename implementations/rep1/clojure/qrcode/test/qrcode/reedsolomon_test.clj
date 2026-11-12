(ns qrcode.reedsolomon-test
  (:require [clojure.test :refer [deftest is]]
            [clojure.test.check.clojure-test :refer [defspec]]
            [clojure.test.check.generators :as gen]
            [clojure.test.check.properties :as prop]
            [qrcode.reedsolomon :as rs]))

(defn- slow-multiply
  "Reference carry-less multiplication reduced modulo 0x11D."
  [a b]
  (loop [a a, b b, acc 0]
    (if (zero? b)
      acc
      (recur (let [a2 (bit-shift-left a 1)] (if (>= a2 256) (bit-xor a2 0x11D) a2))
             (bit-shift-right b 1)
             (if (odd? b) (bit-xor acc a) acc)))))

(def byte-gen (gen/choose 0 255))

(defspec multiply-matches-reference 500
  (prop/for-all [a byte-gen, b byte-gen]
    (= (rs/multiply a b) (slow-multiply a b))))

(defspec multiply-commutes-and-distributes 200
  (prop/for-all [a byte-gen, b byte-gen, c byte-gen]
    (and (= (rs/multiply a b) (rs/multiply b a))
         (= (rs/multiply a (bit-xor b c))
            (bit-xor (rs/multiply a b) (rs/multiply a c))))))

(deftest generator-polynomials
  ;; Degree 7 generator from ISO/IEC 18004 (alpha exponents 87 229 146 149 238 102 21).
  (is (= [127 122 154 164 11 68 117] (vec (rs/generator 7)))))

(deftest hello-world-ecc
  (is (= [196 35 39 119 235 215 231 226 93 23]
         (vec (rs/remainder (int-array [32 91 11 120 209 114 220 77 67 64 236 17 236 17 236 17])
                            10)))))

(defn- eval-poly
  "Evaluates the polynomial (highest degree first) at x in GF(2^8)."
  [coeffs x]
  (reduce (fn [acc c] (bit-xor (rs/multiply acc x) c)) 0 coeffs))

(defspec codeword-has-zero-syndromes 100
  (prop/for-all [data (gen/vector byte-gen 1 120)
                 degree (gen/elements [7 10 13 17 22 30])]
    (let [ecc (vec (rs/remainder (int-array data) degree))
          codeword (into data ecc)]
      ;; data(x) x^E + remainder is divisible by prod (x - 2^i).
      (loop [i 0, root 1]
        (cond (= i degree) true
              (not (zero? (eval-poly codeword root))) false
              :else (recur (inc i) (rs/multiply root 2)))))))
