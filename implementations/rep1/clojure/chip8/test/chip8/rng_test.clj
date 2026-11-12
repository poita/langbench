(ns chip8.rng-test
  (:require [chip8.rng :as rng]
            [clojure.test :refer [deftest is]]))

(deftest spec-sequence
  (is (= [0x0b719151 0x6f47bdb6 0x2e1d6ab7]
         (take 3 (rest (iterate rng/next-state rng/seed)))))
  (is (= [0x71 0x47 0x1d] (take 3 (rng/sequence-of-bytes)))))
