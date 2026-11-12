(ns regex.reference
  "A deliberately naive, purely functional transcription of section 3 of the
  specification, used as an oracle by the property tests.  It works directly on
  the parser's syntax tree with immutable capture maps, so backtracking needs
  no undo logic."
  (:require [regex.charset :as cs]
            [regex.parser :as parser]))

(defn- m
  "Matches `node` at `i`; `k` is called with (j caps) and returns a truthy
  result on overall success or nil."
  [^String s node i caps k]
  (let [len (.length s)]
    (case (node 0)
      :char (and (< i len) (= (int (.charAt s i)) (node 1)) (k (inc i) caps))
      :any (and (< i len) (k (inc i) caps))
      :set (and (< i len) (cs/member? (node 1) (.charAt s i)) (k (inc i) caps))
      :bol (and (zero? i) (k i caps))
      :eol (and (= i len) (k i caps))
      :seq (let [step (fn step [xs i caps]
                        (if (empty? xs)
                          (k i caps)
                          (m s (first xs) i caps (fn [j c] (step (rest xs) j c)))))]
             (step (node 1) i caps))
      :alt (some (fn [b] (m s b i caps k)) (node 1))
      :group (let [g (node 1)]
               (m s (node 2) i caps (fn [j c] (k j (assoc c g [i j])))))
      :rep (let [[_ x mn mx] (vec node)
                 rep (fn rep [i n caps]
                       (cond
                         (< n mn) (m s x i caps (fn [j c] (rep j (inc n) c)))
                         (and mx (= n mx)) (k i caps)
                         :else (or (m s x i caps
                                      (fn [j c] (if (= j i) (k j c) (rep j (inc n) c))))
                                   (k i caps))))]
             (rep i 0 caps)))))

(defn find-match
  "Reference implementation of regex.core/find-match, taking a pattern string."
  [^String pattern ^String s]
  (let [{:keys [ast groups]} (parser/parse pattern)]
    (some (fn [start]
            (m s ast start {} (fn [j caps] {:start start :end j
                                            :groups (mapv #(get caps %) (range 1 (inc groups)))})))
          (range (inc (.length s))))))
