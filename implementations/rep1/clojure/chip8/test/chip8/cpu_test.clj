(ns chip8.cpu-test
  (:require [chip8.core :as core]
            [chip8.machine :as machine]
            [chip8.test-util :refer [reg run-ops v]]
            [clojure.test :refer [deftest is testing]]))

(deftest load-and-add
  (let [m (run-ops [0x60ff 0x7001 0x6101 0x8014])]
    (is (= 1 (v m 0)))
    (is (= 0 (v m 0xF)) "7XNN leaves VF alone; 8XY4 set it to 0")))

(deftest add-carry-and-flag-wins
  (let [m (run-ops [0x60ff 0x6102 0x8014])]
    (is (= 1 (v m 0)))
    (is (= 1 (v m 0xF))))
  (testing "X = F: flag written last"
    (let [m (run-ops [0x6fff 0x6101 0x8f14])]
      (is (= 1 (v m 0xF))))))

(deftest subtraction
  (let [m (run-ops [0x6005 0x6107 0x8015])]
    (is (= 0xFE (v m 0)))
    (is (= 0 (v m 0xF))))
  (let [m (run-ops [0x6007 0x6107 0x8015])]
    (is (= 0 (v m 0)))
    (is (= 1 (v m 0xF)) "equal operands: no borrow"))
  (let [m (run-ops [0x6005 0x6107 0x8017])]
    (is (= 2 (v m 0)))
    (is (= 1 (v m 0xF)))))

(deftest shifts-ignore-vy
  (let [m (run-ops [0x6003 0x61ff 0x8016])]
    (is (= 1 (v m 0)))
    (is (= 1 (v m 0xF))))
  (let [m (run-ops [0x60c1 0x8ffe])]
    (is (= 0 (v m 0xF)) "VX=0, flag overwritten by shift of VF itself"))
  (let [m (run-ops [0x60c1 0x800e])]
    (is (= 0x82 (v m 0)))
    (is (= 1 (v m 0xF)))))

(deftest skips
  (is (= 0x206 (reg (run-ops [0x6001 0x3001]) :pc)) "3XNN taken")
  (is (= 0x204 (reg (run-ops [0x4002]) :pc)) "4XNN taken (V0=0 != 2)")
  (is (= 0x204 (reg (run-ops [0x5010]) :pc)) "5XY0 taken")
  (is (= 0x202 (reg (run-ops [0x9010]) :pc)) "9XY0 not taken")
  (testing "invalid low nibble is a no-op"
    (is (= 0x202 (reg (run-ops [0x5011]) :pc)))
    (is (= 0x202 (reg (run-ops [0x9011]) :pc)))))

(deftest unknown-opcodes-are-nops
  (doseq [op [0x0123 0x8018 0xE000 0xF0FF]]
    (let [m (run-ops [op])]
      (is (= 0x202 (reg m :pc)) (format "%04x" op))
      (is (= (vec (repeat 16 0)) (:v (machine/snapshot m)))))))

(deftest calls-and-returns
  (let [m (run-ops [0x2206 0x1202 0x1202 0x00ee] 1)]
    (is (= 0x206 (reg m :pc)))
    (is (= 1 (reg m :sp))))
  (let [m (run-ops [0x2204 0x1202 0x00ee] 3)]
    (is (= 0x202 (reg m :pc)))
    (is (= 0 (reg m :sp)))))

(deftest full-stack
  (let [calls (for [k (range 16)] (+ 0x2000 (+ 0x202 (* 2 k))))
        m (run-ops (vec calls) 16)]
    (is (= 16 (reg m :sp)))))

(deftest jump-with-offset-wraps
  (let [m (run-ops [0x6003 0xbffe] 2)]
    (is (= 0x001 (reg m :pc)) "(0xffe + 3) & 0xfff")))

(deftest random-bytes
  (let [m (run-ops [0xc0ff 0xc1ff 0xc20f 0xc300])]
    (is (= [0x71 0x47 0x0d 0x00] (subvec (:v (machine/snapshot m)) 0 4)))
    ))

(deftest index-register
  (let [m (run-ops [0xaffe 0x60ff 0xf01e])]
    (is (= (+ 0xffe 0xff) (reg m :i))))
  (let [m (run-ops [0xafff 0x60ff 0xf01e 0xf01e 0xf01e])]
    (is (= (+ 0xfff (* 3 0xff)) (reg m :i)))))

(deftest bcd-and-register-blocks
  (let [m (run-ops [0x609c 0xa300 0xf033 0x6100 0x6200 0x6300 0xa300 0xf265])]
    (is (= [1 5 6] (subvec (:v (machine/snapshot m)) 0 3))
        "BCD of 156 stored at I, read back with FX65")
    (is (= 0x300 (reg m :i)) "neither FX33 nor FX65 modify I"))
  (testing "FX55/FX65 round trip with address wrap"
    (let [m (run-ops [0x6011 0x6122 0x6233 0xafff 0xf255 0x6000 0x6100 0x6200 0xf265])]
      (is (= [0x11 0x22 0x33] (subvec (:v (machine/snapshot m)) 0 3)))
      (is (= 0xfff (reg m :i))))))

(deftest font-address
  (let [m (run-ops [0x601a 0xf029])]
    (is (= (+ 0x50 (* 5 0xa)) (reg m :i)))))

(deftest timers
  (let [m (run-ops [0x6008 0xf015 0x1204 0x1204 0x1204] 8)]
    (is (= 7 (reg m :dt))))
  (let [m (run-ops [0x6002 0xf018 0x1204] 16)]
    (is (= 0 (reg m :st)))))

(deftest keys-and-wait
  (let [m (run-ops [0x6005 0xe09e 0x6101] 3 [[0 0x0020]])]
    (is (= 0 (v m 1)) "EX9E skips when key 5 held"))
  (let [m (run-ops [0xf00a] 3)]
    (is (= 0x200 (reg m :pc)) "FX0A re-executes until a key is pressed"))
  (let [m (run-ops [0xf00a] 2 [[1 0x0c00]])]
    (is (= 10 (v m 0)) "lowest pressed key wins")
    (is (= 0x202 (reg m :pc))))
  (testing "event at cycle N never applies"
    (let [m (run-ops [0xf00a] 3 [[3 0x0001]])]
      (is (= 0x200 (reg m :pc))))))

(deftest self-modifying-code
  ;; FX55 overwrites the nop at 0x20A with `6377`, which then executes.
  (let [m (run-ops [0x6063 0x6177 0xa20a 0xf155 0x0000 0x0000] 6)]
    (is (= 0x77 (v m 3)))))
