(ns chip8.properties-test
  (:require [chip8.core :as core]
            [chip8.test-util :refer [reg v]]
            [clojure.string :as str]
            [clojure.test :refer [deftest is]]
            [clojure.test.check.clojure-test :refer [defspec]]
            [clojure.test.check.generators :as gen]
            [clojure.test.check.properties :as prop]))

(def byte-gen (gen/choose 0 255))

(defspec add-matches-mod-256 100
  (prop/for-all [a byte-gen b byte-gen]
    (let [m (core/run [0x60 a 0x61 b 0x80 0x14] 3)]
      (and (= (bit-and (+ a b) 0xff) (v m 0))
           (= (if (> (+ a b) 255) 1 0) (v m 0xf))))))

(defspec sub-sets-no-borrow-flag 100
  (prop/for-all [a byte-gen b byte-gen]
    (let [m (core/run [0x60 a 0x61 b 0x80 0x15] 3)]
      (and (= (bit-and (- a b) 0xff) (v m 0))
           (= (if (>= a b) 1 0) (v m 0xf))))))

(defspec bcd-digits 100
  (prop/for-all [a byte-gen]
    ;; V0=a; I=0x300; BCD; I=0x300; V0..V2 <- mem
    (let [m (core/run [0x60 a 0xa3 0x00 0xf0 0x33 0xf2 0x65] 4)]
      (= [(quot a 100) (mod (quot a 10) 10) (mod a 10)]
         [(v m 0) (v m 1) (v m 2)]))))

(defspec output-shape 25
  (prop/for-all [rom (gen/vector byte-gen 2 64)
                 cycles (gen/choose 0 500)]
    (let [lines (str/split-lines (core/format-state (core/run rom cycles)))]
      (and (= 34 (count lines))
           (every? #(re-matches #"[#.]{64}" %) (take 32 lines))
           (re-matches #"PC=[0-9a-f]{4} I=[0-9a-f]{4} SP=\d+ DT=[0-9a-f]{2} ST=[0-9a-f]{2}"
                       (lines 32))
           (re-matches #"V=([0-9a-f]{2} ){15}[0-9a-f]{2}" (lines 33))))))

(defspec runs-are-deterministic 25
  (prop/for-all [rom (gen/vector byte-gen 2 64)
                 cycles (gen/choose 0 300)]
    (= (core/format-state (core/run rom cycles))
       (core/format-state (core/run rom cycles)))))

(defspec pc-stays-12-bit 25
  ;; The program counter always stays within 12 bits.
  (prop/for-all [rom (gen/vector byte-gen 2 64)
                 cycles (gen/choose 0 300)]
    (<= 0 (reg (core/run rom cycles) :pc) 0xfff)))
