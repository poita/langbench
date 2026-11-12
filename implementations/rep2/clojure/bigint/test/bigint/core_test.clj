(ns bigint.core-test
  (:require [bigint.core :as bi]
            [clojure.test :refer [deftest is testing]]))

(defn- p [s] (bi/parse s))
(defn- str-of [x] (bi/->string x))

(deftest parsing-and-printing
  (testing "canonical output"
    (is (= "0" (str-of (p "0"))))
    (is (= "0" (str-of (p "-0"))))
    (is (= "0" (str-of (p "-000"))))
    (is (= "7" (str-of (p "007"))))
    (is (= "-123" (str-of (p "-000123")))))
  (testing "malformed input"
    (doseq [bad ["" "-" "+5" "1 2" "1e3" "--1" "12.5"]]
      (is (thrown? clojure.lang.ExceptionInfo (p bad)) bad)))
  (testing "from-long"
    (is (= "-9223372036854775808" (str-of (bi/from-long Long/MIN_VALUE))))
    (is (= (p "12345") (bi/from-long 12345)))))

(deftest equality-and-ordering
  (is (= (p "0") (p "-0")))
  (is (= (p "7") (p "007")))
  (is (= (hash (p "7")) (hash (p "000007"))))
  (is (not= (p "7") (p "-7")))
  (is (= 0 (bi/cmp (p "-0") (p "0"))))
  (is (= -1 (bi/cmp (p "-3") (p "-2"))))
  (is (= 1 (bi/cmp (p "10") (p "9"))))
  (is (= -1 (bi/cmp (p "-100") (p "1"))))
  (is (= 1 (bi/cmp (p "1") (p "-100"))))
  (is (= [(p "-5") (p "0") (p "3") (p "20")]
         (sort [(p "20") (p "3") (p "-5") (p "0")]))))

(deftest predicates
  (is (bi/zero? (p "-0")))
  (is (bi/neg? (p "-1")))
  (is (bi/pos? (p "1")))
  (is (= -1 (bi/signum (p "-99999999999999999999"))))
  (is (= "5" (str-of (bi/abs (p "-5")))))
  (is (= "-5" (str-of (bi/negate (p "5")))))
  (is (= "0" (str-of (bi/negate (p "0"))))))

(deftest signed-addition-and-subtraction
  (doseq [[a b sum diff]
          [["12" "30" "42" "-18"]
           ["5" "-7" "-2" "12"]
           ["-5" "7" "2" "-12"]
           ["-5" "-7" "-12" "2"]
           ["-0" "0" "0" "0"]
           ["7" "-7" "0" "14"]
           ["99999999999999999999" "1" "100000000000000000000" "99999999999999999998"]
           ["1000000000000000000000000000000" "-1" "999999999999999999999999999999"
            "1000000000000000000000000000001"]]]
    (is (= sum (str-of (bi/add (p a) (p b)))) (str a " + " b))
    (is (= diff (str-of (bi/sub (p a) (p b)))) (str a " - " b))))

(deftest signed-multiplication
  (is (= "0" (str-of (bi/mul (p "-5") (p "0")))))
  (is (= "-6" (str-of (bi/mul (p "2") (p "-3")))))
  (is (= "6" (str-of (bi/mul (p "-2") (p "-3"))))))

(deftest division-semantics
  (doseq [[a b q r] [["7" "2" "3" "1"]
                     ["-7" "2" "-3" "-1"]
                     ["7" "-2" "-3" "1"]
                     ["-7" "-2" "3" "-1"]
                     ["-1" "3" "0" "-1"]
                     ["-1" "2" "0" "-1"]
                     ["-7" "7" "-1" "0"]
                     ["0" "5" "0" "0"]]]
    (let [[qq rr] (bi/quot-rem (p a) (p b))]
      (is (= q (str-of qq)) (str a " / " b))
      (is (= r (str-of rr)) (str a " % " b))
      (is (= q (str-of (bi/quot (p a) (p b)))))
      (is (= r (str-of (bi/rem (p a) (p b)))))))
  (testing "division by zero"
    (doseq [z ["0" "-0" "000"]]
      (is (= ::bi/division-by-zero
             (try (bi/quot (p "5") (p z))
                  (catch clojure.lang.ExceptionInfo e (:type (ex-data e)))))))
    (is (thrown? clojure.lang.ExceptionInfo (bi/rem (p "0") (p "0"))))))

(deftest exponentiation
  (is (= "1" (str-of (bi/pow (p "0") (p "0")))))
  (is (= "0" (str-of (bi/pow (p "0") (p "5")))))
  (is (= "1" (str-of (bi/pow (p "-7") (p "-0")))))
  (is (= "-8" (str-of (bi/pow (p "-2") (p "3")))))
  (is (= "4" (str-of (bi/pow (p "-2") (p "2")))))
  (is (= "-1" (str-of (bi/pow (p "-1") (p "999")))))
  (is (= "1" (str-of (bi/pow (p "-1") (p "1000")))))
  (is (= "1" (str-of (bi/pow (p "1") (p "123456789012345678901234567890")))))
  (is (= "1024" (str-of (bi/pow (p "2") (p "0010")))))
  (is (= ::bi/negative-exponent
         (try (bi/pow (p "2") (p "-1"))
              (catch clojure.lang.ExceptionInfo e (:type (ex-data e)))))))
