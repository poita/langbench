(ns bigint.mag-test
  (:require [bigint.mag :as mag]
            [clojure.string :as str]
            [clojure.test :refer [deftest is testing]]))

(defn- m [s] (mag/parse s 0 (count s)))
(defn- s [a] (mag/->digits a))
(defn- limbs [a] (vec a))

(deftest parse-and-print
  (testing "limb layout is little-endian base 10^9"
    (is (= [] (limbs (m "0"))))
    (is (= [] (limbs (m "0000"))))
    (is (= [5] (limbs (m "005"))))
    (is (= [0 1] (limbs (m "1000000000"))))
    (is (= [999999999 999999999 1] (limbs (m "1999999999999999999")))))
  (testing "round trip"
    (doseq [x ["0" "1" "999999999" "1000000000" "123456789012345678901234567890"
               (apply str (repeat 50 "9"))]]
      (is (= x (s (m x))))))
  (testing "interior zero limbs are padded when printing"
    (is (= "1000000000000000001" (s (m "1000000000000000001")))))
  (testing "non-digits are rejected"
    (is (thrown? clojure.lang.ExceptionInfo (m "12a4")))))

(deftest from-long-test
  (is (= "0" (s (mag/from-long 0))))
  (is (= "9223372036854775807" (s (mag/from-long Long/MAX_VALUE))))
  (is (= "9223372036854775808" (s (mag/from-long Long/MIN_VALUE))))
  (is (= "42" (s (mag/from-long -42)))))

(deftest comparison
  (is (= 0 (mag/cmp (m "0") (m "000"))))
  (is (= -1 (mag/cmp (m "999999999") (m "1000000000"))))
  (is (= 1 (mag/cmp (m "2000000000000000000") (m "1999999999999999999"))))
  (is (= -1 (mag/cmp (m "1999999999999999999") (m "2000000000000000000")))))

(deftest addition-and-subtraction
  (is (= "1000000000" (s (mag/add (m "999999999") (m "1")))))
  (is (= "100000000000000000000" (s (mag/add (m "99999999999999999999") (m "1")))))
  (is (= "5" (s (mag/add (m "0") (m "5")))))
  (is (= "999999999" (s (mag/sub (m "1000000000") (m "1")))))
  (is (= "999999999999999999999999999999"
         (s (mag/sub (m "1000000000000000000000000000000") (m "1")))))
  (is (= "0" (s (mag/sub (m "123456789123456789") (m "123456789123456789"))))))

(deftest multiplication
  (is (= "0" (s (mag/mul (m "0") (m "123")))))
  (is (= "121932631137021795226185032733622923332237463801111263526900"
         (s (mag/mul (m "123456789012345678901234567890")
                     (m "987654321098765432109876543210")))))
  (testing "(10^k - 1)^2 = 10^2k - 2*10^k + 1"
    (let [k 40, nines (str/join (repeat k "9"))]
      (is (= (str (str/join (repeat (dec k) "9")) "8"
                  (str/join (repeat (dec k) "0")) "1")
             (s (mag/mul (m nines) (m nines))))))))

(deftest division
  (testing "single-limb divisor"
    (let [[q r] (mag/divmod (m "1000000000000000000000") (m "7"))]
      (is (= "142857142857142857142" (s q)))
      (is (= "6" (s r)))))
  (testing "dividend smaller than divisor"
    (let [[q r] (mag/divmod (m "5") (m "100000000000000000000"))]
      (is (= "0" (s q)))
      (is (= "5" (s r)))))
  (testing "multi-limb divisor"
    (let [[q r] (mag/divmod (m "121932631137021795226185032733622923332237463801111263526900")
                            (m "987654321098765432109876543210"))]
      (is (= "123456789012345678901234567890" (s q)))
      (is (= "0" (s r)))))
  (testing "add-back step of Algorithm D (initial quotient estimate too large)"
    ;; (B^4) / (B^2 + 1) with B = 10^9: the first estimate is one too big.
    (let [[q r] (mag/divmod (m (str "1" (apply str (repeat 36 "0"))))
                            (m (str "1" (apply str (repeat 17 "0")) "1")))]
      (is (= "999999999999999999" (s q)))
      (is (= "1" (s r)))))
  (testing "division by zero"
    (is (thrown? ArithmeticException (mag/divmod (m "1") (m "0"))))))

(deftest exponentiation
  (is (= "1" (s (mag/pow (m "0") 0))))
  (is (= "1024" (s (mag/pow (m "2") 10))))
  (is (= "1" (s (mag/pow (m "12345") 0))))
  (is (= "12345" (s (mag/pow (m "12345") 1))))
  (is (= "1267650600228229401496703205376" (s (mag/pow (m "2") 100)))))

(deftest parity
  (is (mag/even-mag? (m "0")))
  (is (mag/even-mag? (m "1000000000000")))
  (is (not (mag/even-mag? (m "1000000000001")))))
