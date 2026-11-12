(ns chip8.core-test
  (:require [clojure.string :as str]
            [clojure.test :refer [deftest is testing]]
            [clojure.test.check.clojure-test :refer [defspec]]
            [clojure.test.check.generators :as gen]
            [clojure.test.check.properties :as prop]
            [chip8.core :as core]))

(def blank-row (apply str (repeat 64 \.)))

(deftest example-1
  (is (= (str (apply str (repeat 32 (str blank-row "\n")))
              "PC=0208 I=0000 SP=0 DT=00 ST=00\n"
              "V=01 01 00 00 00 00 00 00 00 00 00 00 00 00 00 00\n")
         (core/emulate "60ff7001610180141208\n6\n"))))

(deftest example-2
  (let [lines (str/split-lines (core/emulate "6a3e6b1e6000f029dab5dab5\n5"))]
    (is (= 34 (count lines)))
    (is (= (str ".#" (apply str (repeat 60 \.)) "#.") (first lines)))
    (is (= (str "##" (apply str (repeat 60 \.)) "##") (nth lines 2)))
    (is (= "PC=020a I=0050 SP=0 DT=00 ST=00" (nth lines 32)))
    (is (= "V=00 00 00 00 00 00 00 00 00 00 3e 1e 00 00 00 00" (nth lines 33)))))

(deftest example-2-second-draw
  (let [lines (str/split-lines (core/emulate "6a3e6b1e6000f029dab5dab5\n6"))]
    (is (every? #(= blank-row %) (take 32 lines)))
    (is (= "PC=020c I=0050 SP=0 DT=00 ST=00" (nth lines 32)))
    (is (= "V=00 00 00 00 00 00 00 00 00 00 3e 1e 00 00 00 01" (nth lines 33)))))

(deftest example-3
  (let [lines (str/split-lines
               (core/emulate "c0ffc1ffc20f6408f415f007e2a11200e4a1120af00a\n14\n9:0300"))]
    (is (= "PC=021e I=0000 SP=0 DT=07 ST=00" (nth lines 32)))
    (is (= "V=08 47 0d 00 08 00 00 00 00 00 00 00 00 00 00 00" (nth lines 33)))))

(deftest zero-cycles
  (is (= "PC=0200 I=0000 SP=0 DT=00 ST=00"
         (nth (str/split-lines (core/emulate "00e0\n0")) 32))))

(deftest self-modifying-code
  (testing "code written to memory is executed"
    (let [rom [0x60 0x70   ; V0 = 0x70
               0x61 0x05   ; V1 = 0x05  (so memory 0x208 = 0x70, 0x209 = 0x05)
               0xA2 0x08   ; I = 0x208
               0xF1 0x55   ; store V0,V1 at 0x208
               0x00 0x00]  ; overwritten with 7005 (V0 += 5)
          s (core/snapshot (core/run-rom rom 5))]
      (is (= 0x75 (get-in s [:v 0]))))))

(defspec draw-twice-restores-display 50
  (prop/for-all [x (gen/choose 0 255) y (gen/choose 0 255) n (gen/choose 0 15)
                 i (gen/choose 0 0xFFF)]
    (let [ops [(+ 0x6000 x) (+ 0x6100 y) (+ 0xA000 i) (+ 0xD010 n)]
          rom (mapcat (fn [op] [(bit-shift-right op 8) (bit-and op 0xFF)]) ops)
          once (core/snapshot (core/run-rom rom 4))
          twice (core/snapshot (core/run-rom (concat rom [0xD0 (+ 0x10 n)]) 5))]
      (and (some? once)
           (every? zero? (flatten (:display twice)))))))

(defspec pc-always-12-bit 50
  (prop/for-all [rom (gen/vector (gen/choose 0 255) 2 200)
                 cycles (gen/choose 0 500)]
    (let [s (core/snapshot (core/run-rom rom cycles))]
      (and (<= 0 (:pc s) 0xFFF)
           (every? #(<= 0 % 255) (:v s))))))
