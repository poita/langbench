(ns scheme.bignum-test
  "Property tests of the integer tower against java.math.BigInteger, used here
  only as a test oracle."
  (:require [clojure.test :refer [deftest is testing]]
            [clojure.test.check.clojure-test :refer [defspec]]
            [clojure.test.check.generators :as gen]
            [clojure.test.check.properties :as prop]
            [scheme.number :as num])
  (:import [java.math BigInteger]))

(defn- parse [^BigInteger b] (num/parse-integer (.toString b)))

(def gen-big
  "BigIntegers of mixed sizes, biased toward boundary values."
  (gen/one-of
   [(gen/fmap #(BigInteger/valueOf %) gen/large-integer)
    (gen/elements (map #(BigInteger. ^String %)
                       ["0" "1" "-1" "9223372036854775807" "-9223372036854775808"
                        "9223372036854775808" "-9223372036854775809"
                        "2147483647" "2147483648" "4611686018427387904"
                        "18446744073709551616" "-18446744073709551616"]))
    (gen/fmap (fn [[bits neg?]]
                (let [v (.shiftLeft BigInteger/ONE (int bits))]
                  (if neg? (.negate v) (.subtract v BigInteger/ONE))))
              (gen/tuple (gen/choose 1 400) gen/boolean))
    (gen/fmap (fn [[digits neg?]]
                (let [v (BigInteger. ^String (apply str digits))]
                  (if neg? (.negate v) v)))
              (gen/tuple (gen/vector (gen/choose 0 9) 1 150) gen/boolean))]))

(defn- same? [x ^BigInteger expected] (= (num/->string x) (.toString expected)))

(defspec parse-print-roundtrip 300
  (prop/for-all [a gen-big] (same? (parse a) a)))

(defspec addition 300
  (prop/for-all [a gen-big b gen-big] (same? (num/add (parse a) (parse b)) (.add ^BigInteger a b))))

(defspec subtraction 300
  (prop/for-all [a gen-big b gen-big] (same? (num/sub (parse a) (parse b)) (.subtract ^BigInteger a b))))

(defspec multiplication 300
  (prop/for-all [a gen-big b gen-big] (same? (num/mul (parse a) (parse b)) (.multiply ^BigInteger a b))))

(defspec quotient-remainder 500
  (prop/for-all [a gen-big b (gen/such-that #(not (zero? (.signum ^BigInteger %))) gen-big)]
    (and (same? (num/quot (parse a) (parse b)) (.divide ^BigInteger a b))
         (same? (num/rem (parse a) (parse b)) (.remainder ^BigInteger a b)))))

(defspec comparison 300
  (prop/for-all [a gen-big b gen-big]
    (= (num/compare-int (parse a) (parse b)) (.compareTo ^BigInteger a b))))

(defspec negation 200
  (prop/for-all [a gen-big] (same? (num/negate (parse a)) (.negate ^BigInteger a))))

(deftest normalisation
  (testing "results that fit in a long are Longs"
    (is (instance? Long (num/sub (parse (BigInteger. "9223372036854775808")) 1)))
    (is (instance? Long (num/negate (parse (BigInteger. "9223372036854775808"))))))
  (testing "edges"
    (is (= "9223372036854775808" (num/->string (num/add Long/MAX_VALUE 1))))
    (is (= "-9223372036854775809" (num/->string (num/sub Long/MIN_VALUE 1))))
    (is (= "9223372036854775808" (num/->string (num/negate Long/MIN_VALUE))))
    (is (= "9223372036854775808" (num/->string (num/quot Long/MIN_VALUE -1))))
    (is (= "0" (num/->string (num/rem Long/MIN_VALUE -1))))
    (is (= 0 (num/parse-integer "-0")))
    (is (= 7 (num/parse-integer "+0007")))))

(deftest knuth-d-corner-cases
  ;; operands that exercise multi-limb divisors and the "add back" step
  (doseq [[a b] [["79228162514264337593543950335" "4294967297"]
                 ["340282366920938463463374607431768211455" "18446744073709551615"]
                 ["1329227995784915872903807060280344576" "36893488147419103232"]
                 ["115792089237316195423570985008687907853269984665640564039457584007913129639935"
                  "340282366920938463463374607431768211457"]]]
    (let [x (BigInteger. ^String a) y (BigInteger. ^String b)]
      (is (same? (num/quot (parse x) (parse y)) (.divide x y)))
      (is (same? (num/rem (parse x) (parse y)) (.remainder x y))))))
