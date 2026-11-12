(ns softfloat.internals-test
  (:require [clojure.test :refer [deftest is testing]]
            [clojure.test.check.clojure-test :refer [defspec]]
            [clojure.test.check.generators :as gen]
            [clojure.test.check.properties :as prop]
            [softfloat.fields :as f]
            [softfloat.hex :as hex]
            [softfloat.round :as round]
            [softfloat.sqrt :as sqrt]))

(deftest field-classification
  (is (f/nan? 0x7fc00000))
  (is (f/nan? 0xff800001))
  (is (not (f/nan? 0x7f800000)))
  (is (f/infinite? 0xff800000))
  (is (f/zero? 0x80000000))
  (is (= [0x800000 -23] (f/unpack 0x3f800000)))
  (is (= [1 -149] (f/unpack 0x00000001)))
  (is (= [0x800000 -172] (f/unpack-normalized 0x00000001))))

(deftest round-pack-cases
  (is (= 0x3f800000 (round/round-pack 0 0x800000 -23 false)) "exact")
  (testing "ties go to even"
    (is (= 0x3f800000 (round/round-pack 0 0x1000001 -24 false)))
    (is (= 0x3f800002 (round/round-pack 0 0x1000003 -24 false))))
  (testing "sticky breaks a tie upwards"
    (is (= 0x3f800000 (round/round-pack 0 0x2000002 -25 false)))
    (is (= 0x3f800001 (round/round-pack 0 0x2000002 -25 true))))
  (testing "overflow"
    (is (= 0x7f800000 (round/round-pack 0 0x800000 105 false)))
    (is (= 0xff800000 (round/round-pack 1 0x800000 105 false))))
  (testing "denormal grid"
    (is (= 0x00800000 (round/round-pack 0 0xffffff -150 false)) "rounds up to smallest normal")
    (is (= 0x00000000 (round/round-pack 0 1 -150 false)) "half of smallest denormal ties to 0")
    (is (= 0x00000001 (round/round-pack 0 1 -150 true)))
    (is (= 0x80000000 (round/round-pack 1 1 -1000 true)))))

(defspec isqrt-is-floor-root 1000
  (prop/for-all [n (gen/choose 0 (bit-shift-left 1 53))]
    (let [[r rem] (sqrt/isqrt-rem n)]
      (and (= n (+ (* r r) rem)) (<= 0 rem (* 2 r))))))

(deftest hex-roundtrip
  (is (= "3f800000" (hex/format-bits 0x3f800000)))
  (is (= "00000001" (hex/format-bits 1)))
  (is (= 0xffffffff (hex/parse "ffffffff"))))
