(ns depresolve.range
  "Version ranges.

  Every range in the input language (`*`, exact, `^`, `~` and comparator
  lists) denotes a half-open interval of versions, represented as
  `{:lo [x y z], :hi [x y z]}` (`:lo` inclusive, `:hi` exclusive). A `:hi` of
  `nil` means unbounded above. An interval with `lo >= hi` is empty."
  (:require [clojure.string :as str]
            [depresolve.version :as version]))

(set! *warn-on-reflection* true)

(def any
  "The range `*`."
  {:lo [0 0 0] :hi nil})

(defn- min-hi [a b]
  (cond (nil? a) b
        (nil? b) a
        (neg? (compare a b)) a
        :else b))

(defn intersect
  "The intersection of two ranges."
  [a b]
  {:lo (if (pos? (compare (:lo a) (:lo b))) (:lo a) (:lo b))
   :hi (min-hi (:hi a) (:hi b))})

(defn empty-range?
  "True when no version satisfies `r`."
  [{:keys [lo hi]}]
  (and (some? hi) (not (neg? (compare lo hi)))))

(defn accepts?
  "True when version vector `v` is accepted by range `r`."
  [{:keys [lo hi]} v]
  (and (not (neg? (compare v lo)))
       (or (nil? hi) (neg? (compare v hi)))))

(defn- caret [[x y z :as v]]
  (cond (pos? x) {:lo v :hi [(inc x) 0 0]}
        (pos? y) {:lo v :hi [0 (inc y) 0]}
        :else {:lo v :hi (version/successor v)}))

(defn- tilde [[x y _ :as v]]
  {:lo v :hi [x (inc y) 0]})

(defn- comparator-range [^String s]
  (let [two? (= \= (.charAt s 1))
        op (subs s 0 (if two? 2 1))
        v (version/parse (subs s (count op)))]
    (case op
      "<" {:lo [0 0 0] :hi v}
      "<=" {:lo [0 0 0] :hi (version/successor v)}
      ">" {:lo (version/successor v) :hi nil}
      ">=" {:lo v :hi nil})))

(defn parse
  "Parses the textual form of a range, e.g. \"*\", \"1.2.3\", \"^1.2.3\",
  \"~1.2.3\" or \">=1.0.0 <2.0.0\"."
  [^String s]
  (case (.charAt s 0)
    \* any
    \^ (caret (version/parse (subs s 1)))
    \~ (tilde (version/parse (subs s 1)))
    (\< \>) (reduce intersect any (map comparator-range (str/split s #" ")))
    (let [v (version/parse s)]
      {:lo v :hi (version/successor v)})))
