(ns depresolve.range-test
  (:require [clojure.test :refer [deftest is are]]
            [depresolve.range :as r]
            [depresolve.version :as v]))

(defn- accepts? [rng ver] (r/in-range? (r/parse rng) (v/parse ver)))

(deftest wildcard-and-exact
  (is (accepts? "*" "0.0.0"))
  (is (accepts? "*" "1000000.0.0"))
  (is (accepts? "1.2.3" "1.2.3"))
  (is (not (accepts? "1.2.3" "1.2.4")))
  (is (not (accepts? "1.2.3" "1.2.2"))))

(deftest caret
  (are [rng ver ok] (= ok (accepts? rng ver))
    "^1.2.3" "1.2.3" true
    "^1.2.3" "1.99.0" true
    "^1.2.3" "2.0.0" false
    "^1.2.3" "1.2.2" false
    "^0.2.3" "0.2.9" true
    "^0.2.3" "0.3.0" false
    "^0.0.3" "0.0.3" true
    "^0.0.3" "0.0.4" false
    "^0.0.0" "0.0.0" true
    "^0.0.0" "0.0.1" false))

(deftest tilde
  (are [rng ver ok] (= ok (accepts? rng ver))
    "~1.2.3" "1.2.9" true
    "~1.2.3" "1.3.0" false
    "~0.0.3" "0.0.9" true
    "~0.0.3" "0.1.0" false
    "~0.0.3" "0.0.2" false))

(deftest comparators
  (are [rng ver ok] (= ok (accepts? rng ver))
    "<1.0.0" "0.9.9" true
    "<1.0.0" "1.0.0" false
    "<=1.0.0" "1.0.0" true
    "<=1.0.0" "1.0.1" false
    ">1.0.0" "1.0.0" false
    ">1.0.0" "1.0.1" true
    ">=1.0.0" "1.0.0" true
    ">=1.0.0 <2.0.0" "1.5.0" true
    ">=1.0.0 <2.0.0" "2.0.0" false
    ">=2.0.0 <1.0.0" "1.5.0" false
    ">=2.0.0 <1.0.0" "2.0.0" false
    ">=1.9.0 <=1.10.0 >1.9.0" "1.9.0" false
    ">=1.9.0 <=1.10.0 >1.9.0" "1.10.0" true))
