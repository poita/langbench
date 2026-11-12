(ns chip8.core-test
  (:require [chip8.core :as core]
            [chip8.test-util :refer [rom]]
            [clojure.string :as str]
            [clojure.test :refer [deftest is testing]]))

(def blank (str/join (repeat 32 (str (apply str (repeat 64 \.)) "\n"))))

(deftest spec-example-1
  (is (= (str blank
              "PC=0208 I=0000 SP=0 DT=00 ST=00\n"
              "V=01 01 00 00 00 00 00 00 00 00 00 00 00 00 00 00\n")
         (core/run-text "60ff7001610180141208\n6\n"))))

(deftest spec-example-2
  (let [out (str/split-lines (core/run-text "6a3e6b1e6000f029dab5dab5\n5\n"))]
    (is (= 34 (count out)))
    (is (= "PC=020a I=0050 SP=0 DT=00 ST=00" (out 32)))
    (is (= "V=00 00 00 00 00 00 00 00 00 00 3e 1e 00 00 00 00" (out 33))))
  (let [out (str/split-lines (core/run-text "6a3e6b1e6000f029dab5dab5\n6"))]
    (is (= "PC=020c I=0050 SP=0 DT=00 ST=00" (out 32)))
    (is (= "V=00 00 00 00 00 00 00 00 00 00 3e 1e 00 00 00 01" (out 33)))))

(deftest spec-example-3
  (is (= (str blank
              "PC=021e I=0000 SP=0 DT=07 ST=00\n"
              "V=08 47 0d 00 08 00 00 00 00 00 00 00 00 00 00 00\n")
         (core/run-text
          "c0ffc1ffc20f6408f415f007e2a11200e4a1120af00a\n14\n9:0300"))))

(deftest zero-cycles
  (is (str/includes? (core/run-text "6001\n0\n") "PC=0200 I=0000 SP=0")))

(deftest pc-wraps-through-top-of-memory
  ;; 3584-byte ROM fills to 0xFFF; execution falls off the end to 0x000.
  (let [r (vec (concat (repeat 3583 0) [0x12]))
        pc-after #(:pc (core/snapshot (core/run r %)))]
    (is (= 0xFFE (pc-after 1791)) "1791 nops reach 0xFFE")
    (is (= 0x000 (pc-after 1792)) "op 0x0012 fetched from 0xFFE..0xFFF -> PC 0")
    (is (= 0x002 (pc-after 1793)))))

(deftest fetch-wraps-across-end-of-memory
  ;; Jump to 0xFFF, where the high byte is 0x12 (end of the ROM) and the low
  ;; byte comes from address 0x000 (zero): the opcode is 0x1200.
  (let [r (vec (concat [0x1f 0xff] (repeat 3581 0) [0x12]))
        after-1 (core/snapshot (core/run r 1))
        after-2 (core/snapshot (core/run r 2))]
    (is (= 0xFFF (:pc after-1)))
    (is (= 0x200 (:pc after-2)))))

(deftest rom-too-large
  (is (thrown? clojure.lang.ExceptionInfo (core/make-machine (repeat 3585 0)))))

(deftest step-api
  (let [m (core/make-machine (rom 0x6a2a))]
    (core/step! m)
    (is (= 0x2a (get-in (core/snapshot m) [:v 0xa])))))
