(ns bigint.properties-test
  "Property-based tests (test.check). Small values are checked against long
  arithmetic; large values against algebraic identities."
  (:require [bigint.core :as bi]
            [clojure.string :as str]
            [clojure.test :refer [deftest is]]
            [clojure.test.check.clojure-test :refer [defspec]]
            [clojure.test.check.generators :as gen]
            [clojure.test.check.properties :as prop]))

(def ^:private digits-only
  "Decimal digit strings (1-200 digits, any leading zeros), biased toward
  limb-boundary patterns such as runs of 9s and 0s."
  (gen/fmap str/join
            (gen/vector (gen/frequency [[3 (gen/elements ["0" "9"])]
                                        [4 (gen/fmap str (gen/choose 0 9))]])
                        1 200)))

(def ^:private big
  (gen/fmap (fn [[neg? s]] (bi/parse (str (when neg? "-") s)))
            (gen/tuple gen/boolean digits-only)))

(def ^:private nonzero-big (gen/such-that (complement bi/zero?) big 100))

(def ^:private small (gen/choose -3000000000 3000000000))

(defspec parse-print-roundtrip 200
  (prop/for-all [neg? gen/boolean s digits-only]
    (let [canon (let [t (str/replace s #"^0+" "")] (if (str/blank? t) "0" t))
          expected (if (and neg? (not= canon "0")) (str "-" canon) canon)]
      (= expected (bi/->string (bi/parse (str (when neg? "-") s)))))))

(defspec small-add-sub-mul-match-long-arithmetic 300
  (prop/for-all [a small b small]
    (let [x (bi/from-long a), y (bi/from-long b)]
      (and (= (str (+ a b)) (bi/->string (bi/add x y)))
           (= (str (- a b)) (bi/->string (bi/sub x y)))
           (= (str (* a b)) (bi/->string (bi/mul x y)))
           (= (Long/signum (compare a b)) (bi/cmp x y))))))

(defspec small-division-matches-long-arithmetic 300
  (prop/for-all [a small b (gen/such-that (complement zero?) small)]
    (let [x (bi/from-long a), y (bi/from-long b)]
      (and (= (str (quot a b)) (bi/->string (bi/quot x y)))
           (= (str (rem a b)) (bi/->string (bi/rem x y)))))))

(defspec add-sub-inverse 200
  (prop/for-all [a big b big]
    (and (= a (bi/sub (bi/add a b) b))
         (= (bi/add a b) (bi/add b a))
         (bi/zero? (bi/sub a a)))))

(defspec multiplication-laws 100
  (prop/for-all [a big b big c big]
    (and (= (bi/mul a b) (bi/mul b a))
         (= (bi/mul a (bi/add b c))
            (bi/add (bi/mul a b) (bi/mul a c))))))

(defspec division-identity 300
  (prop/for-all [a big b nonzero-big]
    (let [[q r] (bi/quot-rem a b)]
      (and (= a (bi/add (bi/mul q b) r))
           (= -1 (bi/cmp (bi/abs r) (bi/abs b)))
           (or (bi/zero? r) (= (bi/signum r) (bi/signum a)))))))

(defspec exact-division 150
  (prop/for-all [a big b nonzero-big]
    (let [[q r] (bi/quot-rem (bi/mul a b) b)]
      (and (= a q) (bi/zero? r)))))

(defspec division-by-near-multiples 150
  ;; Dividing (b*q + (b-1)) and (b*q) exercises the quotient-digit estimate
  ;; at its edges.
  (prop/for-all [q big b nonzero-big]
    (let [b (bi/abs b), q (bi/abs q)
          top (bi/add (bi/mul b q) (bi/sub b bi/one))
          [q1 r1] (bi/quot-rem top b)]
      (and (= q q1) (= r1 (bi/sub b bi/one))))))

(defspec pow-matches-repeated-multiplication 100
  (prop/for-all [a big e (gen/choose 0 12)]
    (= (bi/pow a (bi/from-long e))
       (reduce (fn [acc _] (bi/mul acc a)) bi/one (range e)))))

(defspec pow-adds-exponents 100
  (prop/for-all [a big e1 (gen/choose 0 20) e2 (gen/choose 0 20)]
    (= (bi/pow a (bi/from-long (+ e1 e2)))
       (bi/mul (bi/pow a (bi/from-long e1)) (bi/pow a (bi/from-long e2))))))

(deftest large-operands
  (let [n  (bi/parse (str/join (repeat 50000 "9")))
        sq (bi/mul n n)
        [q r] (bi/quot-rem sq n)]
    (is (= 100000 (count (bi/->string sq))))
    (is (= n q))
    (is (bi/zero? r))
    (is (= sq (bi/pow n (bi/from-long 2))))))
