(ns depresolve.input-test
  (:require [clojure.test :refer [deftest is]]
            [depresolve.input :as input]
            [depresolve.range :as range]))

(deftest empty-root-only
  (is (= {:registry [] :root []} (input/parse "root:\n"))))

(deftest registry-and-root
  (let [p (input/parse "a 1.0.0: c ^1.0.0, d >=1.0.0 <2.0.0\nc 1.10.0:\nroot: a *\n")]
    (is (= [{:name "a" :version [1 0 0]
             :requirements [{:name "c" :range (range/parse "^1.0.0")}
                            {:name "d" :range (range/parse ">=1.0.0 <2.0.0")}]}
            {:name "c" :version [1 10 0] :requirements []}]
           (:registry p)))
    (is (= [{:name "a" :range range/any}] (:root p)))))

(deftest hyphenated-names
  (is (= "my-lib2" (-> (input/parse "my-lib2 1.0.0:\nroot: my-lib2 *\n")
                       :registry first :name))))
