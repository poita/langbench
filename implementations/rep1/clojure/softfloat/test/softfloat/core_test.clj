(ns softfloat.core-test
  (:require [clojure.test :refer [deftest is testing are]]
            [softfloat.core :as sf]))

(deftest spec-example-1
  (is (= 0x40000000 (sf/add 0x3f800000 0x3f800000)))
  (is (= 0x00000000 (sf/sub 0x3f800000 0x3f800000)))
  (is (= 0xc1100000 (sf/mul 0x40400000 0xc0400000)))
  (is (= 0x3eaaaaab (sf/div 0x3f800000 0x40400000)))
  (is (= 0x3fb504f3 (sf/sqrt 0x40000000))))

(deftest spec-example-2-specials
  (are [expected actual] (= expected actual)
    0x7fc00000 (sf/add 0x7f800000 0xff800000)
    0x7fc00000 (sf/mul 0x7f800000 0x00000000)
    0x7fc00000 (sf/div 0x00000000 0x00000000)
    0x80000000 (sf/sqrt 0x80000000)
    0x7fc00000 (sf/sqrt 0xbf800000)
    0x80000000 (sf/mul 0x00000000 0xbf800000)
    0x80000000 (sf/add 0x80000000 0x80000000)
    0x00000000 (sf/add 0x80000000 0x00000000)
    0xff800000 (sf/div 0xbf800000 0x00000000)
    0x7fc00000 (sf/add 0x7fc12345 0x3f800000)))

(deftest spec-example-3-edges
  (are [expected actual] (= expected actual)
    0x7f800000 (sf/add 0x7f7fffff 0x73000000)
    0x7f7fffff (sf/add 0x7f7fffff 0x72ffffff)
    0x00000000 (sf/div 0x00000001 0x40000000)
    0x00000002 (sf/div 0x00000003 0x40000000)
    0x3f800000 (sf/add 0x3f800000 0x33800000)
    0x3f800002 (sf/add 0x3f800001 0x33800000)
    0x3f800000 (sf/add 0x3f800000 0x33000000)
    0x00000000 (sf/mul 0x00000001 0x3f000000)))

(deftest signed-zeros-and-infinities
  (are [expected actual] (= expected actual)
    0x80000000 (sf/sub 0x80000000 0x00000000)
    0x00000000 (sf/sub 0x80000000 0x80000000)
    0x3f800000 (sf/add 0x80000000 0x3f800000)
    0x80000000 (sf/mul 0x80000001 0x3f000000)
    0x7f800000 (sf/add 0x7f800000 0x7f800000)
    0xff800000 (sf/add 0xff800000 0x3f800000)
    0x80000000 (sf/div 0x80000000 0x7f800000)
    0x7f800000 (sf/sqrt 0x7f800000)
    0x7fc00000 (sf/sqrt 0xff800000)
    0x7fc00000 (sf/div 0x7f800000 0xff800000)))

(deftest denormal-boundaries
  (testing "rounding up out of the denormal range gives the smallest normal"
    (is (= 0x00800000 (sf/add 0x007fffff 0x00000001))))
  (testing "sqrt of denormals"
    (is (= 0x1a3504f3 (sf/sqrt 0x00000001)))))

(deftest eval-op-dispatch
  (is (= 0x40000000 (sf/eval-op "add" [0x3f800000 0x3f800000])))
  (is (= 0x3fb504f3 (sf/eval-op "sqrt" [0x40000000])))
  (is (thrown? clojure.lang.ExceptionInfo (sf/eval-op "pow" [1 2]))))
