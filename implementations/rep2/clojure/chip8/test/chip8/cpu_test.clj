(ns chip8.cpu-test
  (:require [clojure.test :refer [deftest is testing]]
            [chip8.test-util :refer [run-ops]]))

(deftest arithmetic-flags
  (testing "8XY4 carry"
    (let [s (run-ops [0x60ff 0x6102 0x8014] 3)]
      (is (= [1 1] [(get-in s [:v 0]) (get-in s [:v 0xF])]))))
  (testing "8XY5 no borrow sets VF"
    (let [s (run-ops [0x6005 0x6103 0x8015] 3)]
      (is (= [2 1] [(get-in s [:v 0]) (get-in s [:v 0xF])]))))
  (testing "8XY5 borrow clears VF"
    (let [s (run-ops [0x6003 0x6105 0x8015] 3)]
      (is (= [0xFE 0] [(get-in s [:v 0]) (get-in s [:v 0xF])]))))
  (testing "8XY7"
    (let [s (run-ops [0x6003 0x6105 0x8017] 3)]
      (is (= [2 1] [(get-in s [:v 0]) (get-in s [:v 0xF])]))))
  (testing "flag wins when X = F"
    (let [s (run-ops [0x6fff 0x6001 0x8f04] 3)]
      (is (= 1 (get-in s [:v 0xF]))))))

(deftest shift-semantics
  (let [s (run-ops [0x6081 0x8006] 2)]
    (is (= [0x40 1] [(get-in s [:v 0]) (get-in s [:v 0xF])])))
  (let [s (run-ops [0x6081 0x800E] 2)]
    (is (= [0x02 1] [(get-in s [:v 0]) (get-in s [:v 0xF])]))))

(deftest control-flow
  (testing "call and return"
    (let [s (run-ops [0x2206 0x6101 0x1204 0x6001 0x00ee] 2)]
      (is (= [0x208 1 [0x202]] [(:pc s) (:sp s) (:stack s)]))))
  (testing "return restores PC"
    (let [s (run-ops [0x2204 0x1202 0x00ee] 3)]
      (is (= [0x202 0] [(:pc s) (:sp s)]))))
  (testing "skips"
    (is (= 0x206 (:pc (run-ops [0x6001 0x3001] 2))))
    (is (= 0x206 (:pc (run-ops [0x6001 0x4002] 2))))
    (is (= 0x204 (:pc (run-ops [0x5010] 1))))
    (is (= 0x202 (:pc (run-ops [0x9010] 1)))))
  (testing "BNNN uses V0 and wraps"
    (is (= 0x001 (:pc (run-ops [0x6002 0xbfff] 2)))))
  (testing "unknown opcodes are no-ops"
    (let [s (run-ops [0x5011 0x8018 0x9013 0xe000 0xf0ff 0x0123] 6)]
      (is (= 0x20c (:pc s)))
      (is (every? zero? (:v s))))))

(deftest memory-ops
  (testing "FX33 BCD and FX65 round trip"
    (let [s (run-ops [0x60fe 0xa300 0xf033 0xf265] 4)]
      (is (= [2 5 4] (subvec (:v s) 0 3)))
      (is (= [2 5 4] (subvec (:memory s) 0x300 0x303)))))
  (testing "FX55 stores V0..VX inclusive"
    (let [s (run-ops [0x6001 0x6102 0x6203 0xa300 0xf155] 5)]
      (is (= [1 2 0] (subvec (:memory s) 0x300 0x303)))))
  (testing "I+k wraps at 0xFFF"
    (let [s (run-ops [0x6007 0x61ff 0xaffe 0xf155 0xf265] 5)]
      (is (= 7 (get-in s [:memory 0xffe])))
      (is (= 0xff (get-in s [:memory 0xfff])))))
  (testing "FX1E can exceed 12 bits; FX29 points at font"
    (let [s (run-ops [0xaffe 0x6005 0xf01e 0x6003 0xf029] 3)]
      (is (= 0x1003 (:i s))))
    (is (= (+ 0x50 (* 5 0xa)) (:i (run-ops [0x600a 0xf029] 2))))))

(deftest drawing
  (testing "wrap-around and collision (spec example 2)"
    (let [ops [0x6a3e 0x6b1e 0x6000 0xf029 0xdab5]
          s (run-ops ops 5)
          d (:display s)]
      (is (= 0 (get-in s [:v 0xF])))
      (is (= [1 1 0] (mapv #(get-in d [2 %]) [62 63 2])))
      (is (= [1 1] [(get-in d [2 0]) (get-in d [2 1])]))
      (let [s2 (run-ops (conj ops 0xdab5) 6)]
        (is (= 1 (get-in s2 [:v 0xF])))
        (is (every? zero? (flatten (:display s2)))))))
  (testing "N=0 draws nothing and clears VF"
    (let [s (run-ops [0x6f01 0xd000] 2)]
      (is (= 0 (get-in s [:v 0xF])))
      (is (every? zero? (flatten (:display s))))))
  (testing "00E0 clears"
    (let [s (run-ops [0xf029 0xd005 0x00e0] 3)]
      (is (every? zero? (flatten (:display s)))))))

(deftest rng
  (let [s (run-ops [0xc0ff 0xc1ff 0xc20f] 3)]
    (is (= [0x71 0x47 0x0d] (subvec (:v s) 0 3)))))

(deftest timers-and-keys
  (testing "timer ticks after the 8th cycle"
    (let [s (run-ops [0x600a 0xf015 0x1204] 8)]
      (is (= 9 (:dt s))))
    (is (= 0 (:dt (run-ops [0x6001 0xf015] 8)))))
  (testing "sound timer"
    (is (= 3 (:st (run-ops [0x6004 0xf018 0x1204] 8 [])))))
  (testing "FX0A waits, then takes lowest key"
    (let [ops [0xf00a 0x1202]]
      (is (= 0x200 (:pc (run-ops ops 5))))
      (let [s (run-ops ops 5 [[2 0x0300]])]
        (is (= 8 (get-in s [:v 0])))
        (is (= 0x202 (:pc (run-ops [0xf00a 0x1202] 3 [[2 0x0300]])))))))
  (testing "EX9E / EXA1"
    (let [ops [0x6003 0xe09e 0x6101 0x6202]]
      (is (= [1 2] [(get-in (run-ops ops 4) [:v 1]) (get-in (run-ops ops 4) [:v 2])]))
      (let [s (run-ops ops 3 [[0 0x0008]])]
        (is (= 0 (get-in s [:v 1])))
        (is (= 0x208 (:pc s))))))
  (testing "event at cycle N never applies"
    (is (= 0 (get-in (run-ops [0xf00a] 1 [[1 0x0001]]) [:v 0])))))
