(ns bigint.core-test
  (:require [bigint.core :as bi]
            [clojure.test :refer [deftest is testing]]))

(defn- p [s] (bi/parse s))
(defn- s [x] (bi/->string x))

(deftest parse-and-print
  (testing "canonical form"
    (is (= "7" (s (p "007"))))
    (is (= "-123" (s (p "-000123"))))
    (is (= "0" (s (p "-0"))))
    (is (= "0" (s (p "-000"))))
    (is (= "0" (s (p "0000")))))
  (testing "long numbers round-trip, including internal zero limbs"
    (let [n (str "1" (apply str (repeat 30 "0")) "5")]
      (is (= n (s (p n))))))
  (testing "malformed input throws"
    (is (thrown? clojure.lang.ExceptionInfo (p "")))
    (is (thrown? clojure.lang.ExceptionInfo (p "-")))
    (is (thrown? clojure.lang.ExceptionInfo (p "12a")))))

(deftest zero-is-canonical
  (is (= bi/zero (p "-0")))
  (is (= bi/zero (bi/mul (p "-5") bi/zero)))
  (is (= bi/zero (bi/sub (p "5") (p "5"))))
  (is (= 0 (bi/signum (bi/negate bi/zero)))))

(deftest of-long-and-to-long
  (is (= "9223372036854775807" (s (bi/of-long Long/MAX_VALUE))))
  (is (= "-9223372036854775808" (s (bi/of-long Long/MIN_VALUE))))
  (is (= -42 (bi/->long (bi/of-long -42))))
  (is (nil? (bi/->long (p "1000000000000000000")))))

(deftest comparison
  (is (= 0 (bi/compare (p "007") (p "7"))))
  (is (= 0 (bi/compare (p "-0") (p "0"))))
  (is (= -1 (bi/compare (p "-3") (p "-2"))))
  (is (= 1 (bi/compare (p "10") (p "9"))))
  (is (= -1 (bi/compare (p "-1000000000000") (p "5"))))
  (is (= [(p "-2") (p "0") (p "3")] (sort [(p "3") (p "0") (p "-2")]))))

(deftest add-sub
  (is (= "42" (s (bi/add (p "12") (p "30")))))
  (is (= "-2" (s (bi/sub (p "5") (p "7")))))
  (is (= "100000000000000000000" (s (bi/add (p "99999999999999999999") (p "1")))))
  (is (= "999999999999999999999999999999"
         (s (bi/sub (p "1000000000000000000000000000000") (p "1")))))
  (is (= "-1" (s (bi/add (p "-1000000000000000000000") (p "999999999999999999999"))))))

(deftest multiplication
  (is (= "-121932631137021795226185032733622923332237463801111263526900"
         (s (bi/mul (p "-123456789012345678901234567890")
                    (p "987654321098765432109876543210")))))
  (is (= "0" (s (bi/mul (p "-5") (p "0"))))))

(deftest division
  (doseq [[a b q r] [[7 2 3 1] [-7 2 -3 -1] [7 -2 -3 1] [-7 -2 3 -1]
                     [-1 3 0 -1] [-1 2 0 -1] [-7 7 -1 0]]]
    (let [[bq br] (bi/quot-rem (bi/of-long a) (bi/of-long b))]
      (is (= [q r] [(bi/->long bq) (bi/->long br)]) (str a " / " b))))
  (testing "multi-limb divisors exercise Algorithm D"
    (let [a (p "100000000000000000000000000000000000000")
          b (p "999999999999999999999")
          [q r] (bi/quot-rem a b)]
      (is (= a (bi/add (bi/mul q b) r)))
      (is (< (bi/compare r b) 0))))
  (testing "add-back case: qhat estimate one too large"
    ;; classic Knuth test pattern in base 10^9
    (let [b (p "1000000000000000000999999999")
          a (bi/mul b (p "999999999999999999999999999"))
          [q r] (bi/quot-rem (bi/add a (p "999999998")) b)]
      (is (= "999999999999999999999999999" (s q)))
      (is (= "999999998" (s r)))))
  (testing "division by zero"
    (is (thrown? ArithmeticException (bi/quot (p "1") bi/zero)))
    (is (thrown? ArithmeticException (bi/rem bi/zero bi/zero)))))

(deftest exponentiation
  (is (= "1024" (s (bi/pow (p "2") (p "10")))))
  (is (= "1" (s (bi/pow (p "0") (p "0")))))
  (is (= "1" (s (bi/pow (p "-0") (p "-00")))))
  (is (= "0" (s (bi/pow (p "0") (p "5")))))
  (is (= "-8" (s (bi/pow (p "-2") 3))))
  (is (= "4" (s (bi/pow (p "-2") 2))))
  (is (= "-1" (s (bi/pow (p "-1") (p "999999999999999999999999999")))))
  (is (= "1267650600228229401496703205376" (s (bi/pow (p "2") 100))))
  (is (thrown? IllegalArgumentException (bi/pow (p "2") (p "-1"))))
  (is (thrown? IllegalArgumentException (bi/pow (p "2") (p "99999999999999999999999")))))
