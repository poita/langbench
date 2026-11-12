(ns cardgame.prng-test
  (:require [clojure.test :refer [deftest is testing]]
            [clojure.test.check.clojure-test :refer [defspec]]
            [clojure.test.check.generators :as gen]
            [clojure.test.check.properties :as prop]
            [cardgame.prng :as prng]))

(defn- unsigned [^long v] (biginteger (Long/toUnsignedString v)))

(deftest seed-7-reference-values
  (let [vals (loop [st (prng/make 7), n 5, out []]
               (if (zero? n)
                 out
                 (let [[st' v] (prng/next-long st)] (recur st' (dec n) (conj out v)))))]
    (is (= ["15130880334998875822" "17123930943180875438" "1648209070578717474"
            "1985375592982671918" "6908966637734145041"]
           (map #(str (unsigned %)) vals)))))

(deftest zero-seed-is-replaced
  (is (= (prng/make 0) (prng/make 0x2545F4914F6CDD1D))))

(deftest shuffle-of-tiny-lists-consumes-nothing
  (let [st (prng/make 5)]
    (is (= [st []] (prng/shuffle-vec st [])))
    (is (= [st [1]] (prng/shuffle-vec st [1])))))

(deftest shuffle-reference
  ;; SPEC 26.12: SEED 7 shuffling #1..#8 gives 6 8 5 2 4 1 3 7.
  (let [[_ v] (prng/shuffle-vec (prng/make 7) [1 2 3 4 5 6 7 8])]
    (is (= [6 8 5 2 4 1 3 7] v))))

(defspec shuffle-is-a-deterministic-permutation 100
  (prop/for-all [seed (gen/large-integer* {:min 0 :max Long/MAX_VALUE})
                 xs (gen/vector gen/small-integer 0 30)]
    (let [[st1 a] (prng/shuffle-vec (prng/make seed) xs)
          [st2 b] (prng/shuffle-vec (prng/make seed) xs)]
      (and (= a b) (= st1 st2) (= (sort a) (sort xs))))))

(defspec below-stays-in-range 100
  (prop/for-all [seed (gen/large-integer* {:min 1 :max Long/MAX_VALUE})
                 n (gen/choose 1 1000)]
    (let [[_ v] (prng/below (prng/make seed) n)]
      (< -1 v n))))
