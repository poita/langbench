(ns softfloat.property-test
  "Property tests against a hardware oracle (see softfloat.oracle)."
  (:require [clojure.test :refer [deftest is]]
            [clojure.test.check.clojure-test :refer [defspec]]
            [clojure.test.check.generators :as gen]
            [clojure.test.check.properties :as prop]
            [softfloat.core :as sf]
            [softfloat.oracle :as oracle]))

(def gen-bits
  "Raw patterns biased towards interesting values: uniform, near-boundary
  exponents, denormals, specials."
  (gen/frequency
   [[4 (gen/choose 0 0xffffffff)]
    [3 (gen/fmap (fn [[s e f]] (bit-or (bit-shift-left s 31) (bit-shift-left e 23) f))
                 (gen/tuple (gen/choose 0 1) (gen/elements [0 1 2 3 100 126 127 128 129 252 253 254 255])
                            (gen/one-of [(gen/choose 0 0x7fffff)
                                         (gen/elements [0 1 0x7fffff 0x400000 0x7ffffe])])))]
    [1 (gen/elements [0 0x80000000 0x7f800000 0xff800000 0x7fc00000 0x00000001
                      0x007fffff 0x00800000 0x7f7fffff 0x3f800000])]]))

(defn- agrees [f g gens]
  (prop/for-all [args (apply gen/tuple gens)]
    (= (apply f args) (apply g args))))

(defspec add-matches-hardware 5000 (agrees sf/add oracle/add [gen-bits gen-bits]))
(defspec sub-matches-hardware 5000 (agrees sf/sub oracle/sub [gen-bits gen-bits]))
(defspec mul-matches-hardware 5000 (agrees sf/mul oracle/mul [gen-bits gen-bits]))
(defspec div-matches-hardware 5000 (agrees sf/div oracle/div [gen-bits gen-bits]))
(defspec sqrt-matches-hardware 5000 (agrees sf/sqrt oracle/sqrt [gen-bits]))

(defspec results-fit-32-bits 2000
  (prop/for-all [a gen-bits b gen-bits]
    (every? #(<= 0 % 0xffffffff) [(sf/add a b) (sf/mul a b) (sf/div a b) (sf/sqrt a)])))
