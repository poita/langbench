(ns depresolve.parse-test
  (:require [clojure.test :refer [deftest is]]
            [depresolve.parse :as p]))

(deftest parses-registry-and-root
  (is (= {:registry {"a" {"1.0.0" [["c" "^1.0.0"] ["d" ">=1.0.0 <2.0.0"]]
                          "2.0.0" []}
                     "c" {"1.1.0" []}}
          :root [["a" "*"] ["c" "~1.1.0"]]}
         (p/parse-input "a 1.0.0: c ^1.0.0, d >=1.0.0 <2.0.0\nc 1.1.0:\na 2.0.0:\nroot: a *, c ~1.1.0\n"))))

(deftest empty-root
  (is (= {:registry {} :root []} (p/parse-input "root:\n"))))
