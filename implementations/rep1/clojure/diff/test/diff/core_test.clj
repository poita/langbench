(ns diff.core-test
  (:require [clojure.test :refer [deftest is testing]]
            [clojure.test.check.clojure-test :refer [defspec]]
            [clojure.test.check.generators :as gen]
            [clojure.test.check.properties :as prop]
            [diff.core :as core]))

(defn- lcs-length
  "Reference O(NM) dynamic-programming LCS, used only to check minimality."
  [a b]
  (let [bv (vec b)]
    (peek
     (reduce (fn [prev x]
               (reduce (fn [row j]
                         (let [y (bv j)]
                           (conj row (if (= x y)
                                       (inc (prev j))
                                       (max (prev (inc j)) (peek row))))))
                       [0]
                       (range (count bv))))
             (vec (repeat (inc (count bv)) 0))
             a))))

(defn- valid? [a b script]
  (and (= a (vec (keep (fn [[op l]] (when (not= op :insert) l)) script)))
       (= b (vec (keep (fn [[op l]] (when (not= op :delete) l)) script)))))

(defn- minimal-valid? [a b]
  (let [s (core/diff a b)]
    (and (valid? a b s)
         (= (core/cost s) (- (+ (count a) (count b)) (* 2 (lcs-length a b)))))))

(deftest paper-example
  (let [a (vec "abcabba"), b (vec "cbabac"), s (core/diff a b)]
    (is (valid? a b s))
    (is (= 5 (core/cost s)))))

(deftest duplicates
  (let [a (vec "xxxyxx"), b (vec "xyxxxy")]
    (is (minimal-valid? a b))
    (is (= 4 (core/cost (core/diff a b))))))

(deftest edge-cases
  (is (= [] (core/diff [] [])))
  (is (= [[:insert "a"]] (core/diff [] ["a"])))
  (is (= [[:delete "a"]] (core/diff ["a"] [])))
  (is (= [[:keep ""] [:keep " "]] (core/diff ["" " "] ["" " "])))
  (is (= 2 (core/cost (core/diff ["a"] ["b"])))))

(deftest disjoint-is-worst-case
  (let [a (mapv #(str "a" %) (range 300)), b (mapv #(str "b" %) (range 300))]
    (is (= 600 (core/cost (core/diff a b))))))

(deftest identical-large
  (let [a (mapv str (range 50000))]
    (is (every? #(= :keep (first %)) (core/diff a a)))))

(deftest patch-example
  (let [a ["a" "b" "c" "d" "e"]
        script (core/parse-script [" a" "-b" "+B" " c" "+c2" "-d" " e" "+f"])]
    (is (= ["a" "B" "c" "c2" "e" "f"] (core/patch a script)))))

(deftest patch-tag-like-content
  (is (= ["-x" " " "5"]
         (core/patch [" "] (core/parse-script ["+-x" "  " "+5"])))))

(deftest patch-rejects-invalid-script
  (is (thrown? clojure.lang.ExceptionInfo (core/patch ["a"] [[:keep "b"]])))
  (is (thrown? clojure.lang.ExceptionInfo (core/patch ["a" "b"] [[:keep "a"]])))
  (is (thrown? clojure.lang.ExceptionInfo (core/parse-script [""])))
  (is (thrown? clojure.lang.ExceptionInfo (core/parse-script ["?x"]))))

(deftest format-roundtrip
  (let [s [[:keep "a"] [:delete ""] [:insert " p "]]]
    (is (= [" "] (core/format-script [[:keep ""]])))
    (is (= [" a" "-" "+ p "] (core/format-script s)))
    (is (= s (core/parse-script (core/format-script s))))))

(def ^:private small-lines
  (gen/vector (gen/elements ["a" "b" "c" "" " " "-x"]) 0 25))

(defspec diff-is-minimal-and-valid 300
  (prop/for-all [a small-lines, b small-lines]
    (minimal-valid? a b)))

(defspec diff-of-related-files 200
  (prop/for-all [a (gen/vector (gen/elements ["a" "b" "c" "d" "e" "f"]) 0 60)
                 edits (gen/vector (gen/tuple gen/nat (gen/elements ["a" "z" nil])) 0 10)]
    (let [b (reduce (fn [v [i x]]
                      (let [i (if (empty? v) 0 (mod i (count v)))]
                        (if x
                          (vec (concat (subvec v 0 i) [x] (subvec v i)))
                          (if (empty? v) v (vec (concat (subvec v 0 i) (subvec v (inc i))))))))
                    a edits)]
      (minimal-valid? a b))))

(defspec patch-inverts-diff 200
  (prop/for-all [a small-lines, b small-lines]
    (= b (core/patch a (core/diff a b)))))

(defspec patch-with-non-minimal-script 200
  (prop/for-all [a small-lines
                 ops (gen/vector (gen/tuple (gen/elements [:keep :delete :insert :ins2])
                                            (gen/elements ["p" "q"]))
                                 0 20)]
    ;; Interleave random inserts with a keep-or-delete decision per A line.
    (let [script (vec (mapcat (fn [line [op x]]
                                (case op
                                  :keep [[:keep line]]
                                  :delete [[:delete line]]
                                  :insert [[:insert x] [:keep line]]
                                  :ins2 [[:delete line] [:insert line]]))
                              a (concat ops (repeat [:keep "p"]))))
          expected (vec (keep (fn [[op l]] (when (not= op :delete) l)) script))]
      (= expected (core/patch a script)))))
