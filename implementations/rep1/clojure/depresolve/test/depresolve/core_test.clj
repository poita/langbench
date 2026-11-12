(ns depresolve.core-test
  (:require [clojure.string :as str]
            [clojure.test :refer [deftest is testing]]
            [clojure.test.check.clojure-test :refer [defspec]]
            [clojure.test.check.generators :as gen]
            [clojure.test.check.properties :as prop]
            [depresolve.core :as core]
            [depresolve.reference :as ref]
            [depresolve.version :as version]))

(defn- lines [& ls] (str (str/join "\n" ls) "\n"))

(deftest spec-example-1-backtracking
  (is (= (lines "a 1.0.0" "b 1.0.0" "c 1.2.5")
         (core/resolve-text
          (lines "a 1.0.0: c ^1.0.0" "b 1.0.0: c ~1.2.0"
                 "c 1.1.0:" "c 1.2.5:" "c 1.3.0:" "root: a *, b *")))))

(deftest spec-example-2-first-solution
  (is (= (lines "a 2.0.0" "b 1.0.5")
         (core/resolve-text
          (lines "a 2.0.0: b ~1.0.0" "a 1.0.0:" "b 1.0.0:" "b 1.0.5:"
                 "b 1.5.0:" "b 2.0.0:" "root: a *, b *")))))

(deftest spec-example-3-conflict
  (is (= "unsatisfiable\n"
         (core/resolve-text
          (lines "a 1.0.0: c ^1.0.0" "b 1.0.0: c ^2.0.0" "c 1.0.0:" "c 2.0.0:"
                 "root: a *, b *")))))

(deftest spec-example-4-requirement-order
  (let [reg ["a 2.0.0: c ^2.0.0" "a 1.0.0: c ^1.0.0"
             "b 2.0.0: c ^1.0.0" "b 1.0.0: c ^2.0.0"
             "c 1.0.0:" "c 2.0.0:"]]
    (is (= (lines "a 2.0.0" "b 1.0.0" "c 2.0.0")
           (core/resolve-text (apply lines (concat reg ["root: a *, b *"])))))
    (is (= (lines "a 1.0.0" "b 2.0.0" "c 1.0.0")
           (core/resolve-text (apply lines (concat reg ["root: b *, a *"])))))))

(deftest edge-cases
  (testing "empty root gives empty output"
    (is (= "" (core/resolve-text "root:\n"))))
  (testing "requirement on a missing package"
    (is (= "unsatisfiable\n" (core/resolve-text "root: ghost *\n"))))
  (testing "empty range"
    (is (= "unsatisfiable\n"
           (core/resolve-text (lines "a 1.0.0:" "root: a >=2.0.0 <1.0.0")))))
  (testing "cycles and self-requirements are allowed"
    (is (= (lines "a 1.0.0" "b 1.0.0")
           (core/resolve-text
            (lines "a 1.0.0: b *, a 1.0.0" "b 1.0.0: a ^1.0.0" "root: a *")))))
  (testing "output is sorted by byte order of names"
    (is (= (lines "my-lib 1.0.0" "my-lib2 1.0.0" "mylib 1.0.0")
           (core/resolve-text
            (lines "mylib 1.0.0:" "my-lib2 1.0.0:" "my-lib 1.0.0:"
                   "root: mylib *, my-lib2 *, my-lib *")))))
  (testing "versions compare numerically"
    (is (= (lines "a 1.10.0")
           (core/resolve-text (lines "a 1.9.0:" "a 1.10.0:" "root: a *"))))))

(deftest programmatic-api
  (let [problem {:registry [{:name "a" :version [1 0 0]
                             :requirements [{:name "b" :range "^1.0.0"}]}
                            {:name "b" :version [1 4 2] :requirements []}
                            {:name "b" :version [2 0 0] :requirements []}]
                 :root [{:name "a" :range "*"}]}]
    (is (= {"a" [1 0 0] "b" [1 4 2]} (core/resolve-problem problem)))
    (is (nil? (core/resolve-problem (assoc problem :root [{:name "b" :range "3.0.0"}]))))
    (is (= {} (core/resolve-problem {:registry [] :root []})))))

(deftest deep-chain-does-not-overflow
  (let [n 3000
        reg (for [i (range n)]
              (str "p" i " 1.0.0:" (when (< (inc i) n) (str " p" (inc i) " *"))))
        text (str (str/join "\n" reg) "\nroot: p0 *\n")
        res (core/resolve-problem (core/parse-input text))]
    (is (= n (count res)))
    (is (= [1 0 0] (res "p2999")))))

(deftest backtracking-through-many-versions
  (let [n 1000
        reg (concat (for [i (range 1 (inc n))] (str "a 1." i ".0:"))
                    ["b 1.0.0: a <1.2.0"])
        text (str (str/join "\n" reg) "\nroot: a *, b *\n")]
    (is (= (lines "a 1.1.0" "b 1.0.0") (core/resolve-text text)))))

;; --- property: the optimised search agrees with the naive transcription ---

(def ^:private names ["a" "b" "c" "d" "e"])

(def gen-range-str
  (gen/let [kind (gen/elements [:any :exact :caret :tilde :cmp :cmp2])
            v (gen/vector (gen/choose 0 3) 3)
            w (gen/vector (gen/choose 0 3) 3)
            op (gen/elements ["<" "<=" ">" ">="])
            op2 (gen/elements ["<" "<=" ">" ">="])]
    (let [s (version/fmt v) t (version/fmt w)]
      (case kind
        :any "*"
        :exact s
        :caret (str "^" s)
        :tilde (str "~" s)
        :cmp (str op s)
        :cmp2 (str op s " " op2 t)))))

(def gen-requirements
  (gen/let [ns (gen/fmap #(vec (distinct %)) (gen/vector (gen/elements names) 0 4))
            rs (gen/vector gen-range-str (count ns))]
    (mapv (fn [n r] {:name n :range r}) ns rs)))

(def gen-problem
  (gen/let [vs (gen/fmap #(vec (distinct %))
                         (gen/vector (gen/tuple (gen/elements names)
                                                (gen/vector (gen/choose 0 3) 3))
                                     0 14))
            reqs (gen/vector gen-requirements (count vs))
            root gen-requirements]
    {:registry (mapv (fn [[n v] r] {:name n :version v :requirements r}) vs reqs)
     :root root}))

(defspec matches-reference-search 300
  (prop/for-all [problem gen-problem]
    (= (some-> (ref/resolve-naive problem) (->> (into (sorted-map))))
       (core/resolve-problem problem))))
