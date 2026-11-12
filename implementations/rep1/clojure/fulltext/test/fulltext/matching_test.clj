(ns fulltext.matching-test
  (:require [clojure.test :refer [deftest is]]
            [clojure.test.check.clojure-test :refer [defspec]]
            [clojure.test.check.generators :as gen]
            [clojure.test.check.properties :as prop]
            [fulltext.index :as idx]
            [fulltext.matching :as m]
            [fulltext.query :as q]))

(defn- occurrences [match]
  (into {} (map (fn [d s] [d (vec s)]) (:docs match) (:starts match))))

(deftest phrase-matching
  (let [index (idx/build-index {"d1" "aa aa aa aa"
                                "d2" "to be or not to be"
                                "d3" "be to"})]
    (is (= {0 [0 1 2]} (occurrences (m/match-atom index ["aa" "aa"]))))
    (is (= [4] (vec (:freqs (m/match-atom index ["aa"])))))
    (is (= {1 [0 4]} (occurrences (m/match-atom index ["to" "be"]))))
    (is (= {1 [0]} (occurrences (m/match-atom index ["to" "be" "or" "not"]))))
    (is (= {} (occurrences (m/match-atom index ["be" "be"]))))
    (is (= {} (occurrences (m/match-atom index ["nope"]))))
    (is (= {} (occurrences (m/match-atom index ["to" "nope"]))))))

(defn- matching-ids
  "Ids of the documents of `index` matched by query text `s`."
  [index s]
  (let [tree (q/parse s)
        ms (into {} (map (fn [a] [a (m/match-atom index a)])) (q/atoms tree))
        bs (m/evaluate (idx/doc-count index) ms tree)]
    (mapv #(:id (nth (:docs index) %)) (.toArray (.stream bs)))))

(deftest boolean-evaluation
  (let [index (idx/build-index {"d0" "cat dog" "d1" "cat" "d2" "dog" "d3" "fish"})]
    (is (= ["d0"] (matching-ids index "cat dog")))
    (is (= ["d0" "d1" "d2"] (matching-ids index "cat OR dog")))
    (is (= ["d1"] (matching-ids index "cat NOT dog")))
    (is (= ["d2" "d3"] (matching-ids index "NOT cat")))
    (is (= ["d0" "d1" "d2" "d3"] (matching-ids index "NOT NOT (cat OR dog OR fish)")))
    (is (= ["d3"] (matching-ids index "NOT (cat OR dog)")))
    (is (= [] (matching-ids index "")) "the empty tree matches nothing")
    (is (= [] (matching-ids index "NOT"))))
  (is (= [] (matching-ids (idx/build-index {}) "cat"))))

;; Property: phrase matching agrees with a naive scan.

(def gen-doc (gen/vector (gen/elements ["aa" "bb" "cc"]) 0 25))

(defn- naive-occurrences [doc phrase]
  (let [n (count phrase)]
    (vec (filter #(= phrase (subvec doc % (+ % n)))
                 (range 0 (inc (- (count doc) n)))))))

(defspec phrase-matches-naive-scan 200
  (prop/for-all [docs (gen/vector gen-doc 1 4)
                 phrase (gen/vector (gen/elements ["aa" "bb" "cc"]) 1 4)]
    (let [corpus (into {} (map-indexed (fn [i d] [(str "d" i) (clojure.string/join " " d)]) docs))
          index (idx/build-index corpus)
          ;; Terms of single letters repeated are stemmed by Porter; use the
          ;; index's own term function so the property is about positions.
          terms (mapv (:term-fn index) phrase)
          match (m/match-atom index terms)
          expected (into {} (keep (fn [[i d]]
                                    (let [occ (naive-occurrences (mapv (:term-fn index) d) terms)]
                                      (when (seq occ) [i occ])))
                                  (map-indexed vector docs)))]
      (and (= expected (occurrences match))
           (= (map count (vals (sort-by key (occurrences match))))
              (vec (:freqs match)))))))
