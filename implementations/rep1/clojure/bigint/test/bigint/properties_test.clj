(ns bigint.properties-test
  "Generative tests. java.math.BigInteger is used here purely as an
  independent oracle; the library itself never touches it."
  (:require [bigint.core :as bi]
            [clojure.test :refer [deftest]]
            [clojure.test.check.clojure-test :refer [defspec]]
            [clojure.test.check.generators :as gen]
            [clojure.test.check.properties :as prop])
  (:import (java.math BigInteger)))

(def digit-str
  "Decimal strings biased toward limb-boundary values (runs of 0 and 9)."
  (gen/let [n (gen/choose 1 80)
            ds (gen/vector (gen/frequency [[5 (gen/choose 0 9)]
                                           [2 (gen/return 0)]
                                           [2 (gen/return 9)]])
                           n)
            neg gen/boolean
            zeros (gen/choose 0 3)]
    (str (when neg "-") (apply str (repeat zeros "0")) (apply str ds))))

(defn- big [^String s] (BigInteger. s))
(defn- check [x ^BigInteger expected] (= (str expected) (bi/->string x)))

(def trials 300)

(defspec parse-print-roundtrip trials
  (prop/for-all [a digit-str]
    (check (bi/parse a) (big a))))

(defspec add-matches-oracle trials
  (prop/for-all [a digit-str b digit-str]
    (check (bi/add (bi/parse a) (bi/parse b)) (.add (big a) (big b)))))

(defspec sub-matches-oracle trials
  (prop/for-all [a digit-str b digit-str]
    (check (bi/sub (bi/parse a) (bi/parse b)) (.subtract (big a) (big b)))))

(defspec mul-matches-oracle trials
  (prop/for-all [a digit-str b digit-str]
    (check (bi/mul (bi/parse a) (bi/parse b)) (.multiply (big a) (big b)))))

(defspec quot-rem-matches-oracle trials
  (prop/for-all [a digit-str b digit-str]
    (or (.equals (big b) BigInteger/ZERO)
        (let [[q r] (bi/quot-rem (bi/parse a) (bi/parse b))
              [eq er] (.divideAndRemainder (big a) (big b))]
          (and (check q eq) (check r er))))))

(defspec division-identity trials
  (prop/for-all [a digit-str b digit-str]
    (let [x (bi/parse a) y (bi/parse b)]
      (or (bi/zero? y)
          (let [[q r] (bi/quot-rem x y)]
            (and (= x (bi/add (bi/mul q y) r))
                 (< (bi/compare (bi/abs r) (bi/abs y)) 0)
                 (or (bi/zero? r) (= (bi/signum r) (bi/signum x)))))))))

(defspec compare-matches-oracle trials
  (prop/for-all [a digit-str b digit-str]
    (= (Integer/signum (.compareTo (big a) (big b)))
       (bi/compare (bi/parse a) (bi/parse b)))))

(defspec pow-matches-oracle 100
  (prop/for-all [a (gen/fmap str (gen/choose -1000000000000 1000000000000))
                 e (gen/choose 0 40)]
    (check (bi/pow (bi/parse a) e) (.pow (big a) (int e)))))
