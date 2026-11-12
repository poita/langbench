(ns depresolve.core-test
  (:require [clojure.test :refer [deftest is testing]]
            [depresolve.core :as core]))

(deftest example-1-diamond-with-backtracking
  (is (= "a 1.0.0\nb 1.0.0\nc 1.2.5\n"
         (core/resolve-text
          "a 1.0.0: c ^1.0.0\nb 1.0.0: c ~1.2.0\nc 1.1.0:\nc 1.2.5:\nc 1.3.0:\nroot: a *, b *\n"))))

(deftest example-2-first-solution-not-globally-newest
  (is (= "a 2.0.0\nb 1.0.5\n"
         (core/resolve-text
          (str "a 2.0.0: b ~1.0.0\na 1.0.0:\nb 1.0.0:\nb 1.0.5:\nb 1.5.0:\nb 2.0.0:\n"
               "root: a *, b *\n")))))

(deftest example-3-conflicting-majors
  (is (= "unsatisfiable\n"
         (core/resolve-text
          "a 1.0.0: c ^1.0.0\nb 1.0.0: c ^2.0.0\nc 1.0.0:\nc 2.0.0:\nroot: a *, b *\n"))))

(deftest example-4-requirement-order-matters
  (let [reg "a 2.0.0: c ^2.0.0\na 1.0.0: c ^1.0.0\nb 2.0.0: c ^1.0.0\nb 1.0.0: c ^2.0.0\nc 1.0.0:\nc 2.0.0:\n"]
    (is (= "a 2.0.0\nb 1.0.0\nc 2.0.0\n" (core/resolve-text (str reg "root: a *, b *\n"))))
    (is (= "a 1.0.0\nb 2.0.0\nc 1.0.0\n" (core/resolve-text (str reg "root: b *, a *\n"))))))

(deftest edge-cases
  (testing "empty root yields empty output"
    (is (= "" (core/resolve-text "root:\n")))
    (is (= "" (core/resolve-text "a 1.0.0:\nroot:\n"))))
  (testing "missing package"
    (is (= "unsatisfiable\n" (core/resolve-text "root: ghost *\n"))))
  (testing "self-requirement and cycles"
    (is (= "a 1.0.0\nb 1.0.0\n"
           (core/resolve-text "a 1.0.0: a *, b *\nb 1.0.0: a ^1.0.0\nroot: a *\n"))))
  (testing "numeric version order and byte-order sorting of names"
    (is (= "my-lib 1.10.0\nmy-lib2 1.0.0\nmylib 1.0.0\n"
           (core/resolve-text
            (str "mylib 1.0.0:\nmy-lib2 1.0.0:\nmy-lib 1.9.0:\nmy-lib 1.10.0:\n"
                 "root: mylib *, my-lib2 *, my-lib *\n")))))
  (testing "chronological backtracking undoes unrelated choices"
    ;; x is chosen before the conflict between a and b, and the conflict
    ;; cannot be fixed by x; the result is unsatisfiable regardless.
    (is (= "unsatisfiable\n"
           (core/resolve-text
            "x 2.0.0:\nx 1.0.0:\na 1.0.0: b ^2.0.0\nb 1.0.0:\nroot: x *, a *, b *\n")))))

(deftest data-api
  (is (= {"a" "1.0.0" "c" "1.3.0"}
         (core/resolve-deps {"a" {"1.0.0" [["c" "^1.0.0"]]}
                             "c" {"1.1.0" [] "1.3.0" []}}
                            [["a" "*"]])))
  (is (= {} (core/resolve-deps {} [])))
  (is (nil? (core/resolve-deps {} [["a" "*"]]))))

(deftest deep-chain-does-not-overflow-the-stack
  (let [n 5000
        text (str (apply str (for [i (range n)]
                               (str "p" i " 1.0.0:" (when (< (inc i) n) (str " p" (inc i) " *")) "\n")))
                  "root: p0 *\n")]
    (is (= n (count (clojure.string/split-lines (core/resolve-text text)))))))
