(ns regex.reference-test
  "Property test: the compiled matcher must agree with a direct, naive
  transcription of the matching definition in SPEC.md section 3 (continuation
  passing over the syntax tree, with persistent capture maps), on randomly
  generated patterns and subjects."
  (:require [clojure.test :refer [deftest is]]
            [clojure.test.check.clojure-test :refer [defspec]]
            [clojure.test.check.generators :as gen]
            [clojure.test.check.properties :as prop]
            [regex.charset :as cs]
            [regex.core :as re]
            [regex.parser :as parser]))

;; ---------------------------------------------------------------- reference

(defn- ref-m
  "m(node, i, k): k is called with [j caps] and returns a final result or nil."
  [^String s node i caps k]
  (let [len (count s)]
    (case (first node)
      :char (when (and (< i len) (= (.charAt s i) (second node))) (k (inc i) caps))
      :any (when (< i len) (k (inc i) caps))
      :set (when (and (< i len) (cs/member? (second node) (.charAt s i))) (k (inc i) caps))
      :bol (when (zero? i) (k i caps))
      :eol (when (= i len) (k i caps))
      :seq (letfn [(go [items i caps]
                     (if (empty? items)
                       (k i caps)
                       (ref-m s (first items) i caps
                              (fn [j caps'] (go (rest items) j caps')))))]
             (go (second node) i caps))
      :alt (some #(ref-m s % i caps k) (second node))
      :group (let [[_ g x] node]
               (ref-m s x i caps (fn [j caps'] (k j (assoc caps' g [i j])))))
      :rep (let [[_ x lo hi] node]
             (letfn [(rep [i count caps]
                       (cond
                         (< count lo)
                         (ref-m s x i caps (fn [j c'] (rep j (inc count) c')))
                         (and hi (= count hi)) (k i caps)
                         :else
                         (or (ref-m s x i caps
                                    (fn [j c'] (if (= j i) (k j c') (rep j (inc count) c'))))
                             (k i caps))))]
               (rep i 0 caps))))))

(defn reference-match [pattern s]
  (let [{:keys [ast groups]} (parser/parse pattern)]
    (some (fn [start]
            (when-let [[end caps] (ref-m s ast start {} (fn [j caps] [j caps]))]
              {:start start :end end
               :groups (mapv #(get caps %) (range 1 (inc groups)))}))
          (range (inc (count s))))))

;; --------------------------------------------------------------- generators

(def ^:private gen-atom
  (gen/elements ["a" "b" "c" "." "[ab]" "[^a]" "\\d" "\\w" "[a-b]" "\\W"]))

(def ^:private gen-quant
  (gen/elements ["" "" "" "*" "+" "?" "{2}" "{0}" "{1,2}" "{2,}" "{0,3}"]))

(defn- gen-regex [depth]
  (if (zero? depth)
    (gen/fmap (fn [[a q]] (str a q)) (gen/tuple gen-atom gen-quant))
    (let [sub (gen/resize 2 (gen-regex (dec depth)))
          branch (gen/fmap #(apply str %) (gen/vector sub 0 3))]
      (gen/frequency
       [[3 (gen/fmap (fn [[a q]] (str a q)) (gen/tuple gen-atom gen-quant))]
        [2 (gen/fmap (fn [[r q]] (str "(" r ")" q)) (gen/tuple (gen-regex (dec depth)) gen-quant))]
        [2 (gen/fmap (fn [[a b]] (str a "|" b)) (gen/tuple branch branch))]
        [1 (gen/return "^")]
        [1 (gen/return "$")]
        [3 branch]]))))

(def ^:private gen-pattern
  (gen/fmap (fn [[a b c]] (str a b c))
            (gen/tuple (gen-regex 2) (gen/elements ["" "" "$" "|a"]) (gen/elements ["" "" "()"]))))

(def ^:private gen-subject
  (gen/fmap #(apply str %) (gen/vector (gen/elements [\a \b \c \1 \_ \space]) 0 8)))

(defspec agrees-with-reference 2000
  (prop/for-all [pattern gen-pattern
                 subjects (gen/vector gen-subject 4)]
    (let [p (re/compile pattern)]
      (every? #(= (reference-match pattern %) (re/match p %)) subjects))))

(deftest reference-sanity
  (is (= {:start 0 :end 2 :groups [[1 2] [0 1]]} (reference-match "(a|(b))+" "ba"))))
