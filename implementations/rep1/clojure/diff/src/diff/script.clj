(ns diff.script
  "Edit scripts: building them from edit masks, applying them, validating
  them, and converting to and from the textual script format.

  An *edit* is a pair `[op line]` with `op` one of `:keep`, `:delete`,
  `:insert`. A script is a vector of edits."
  (:require [clojure.string :as str]))

(set! *warn-on-reflection* true)

(def ^:private op->tag {:keep \space, :delete \-, :insert \+})
(def ^:private tag->op {\space :keep, \- :delete, \+ :insert})

(defn from-masks
  "Builds the script (in file order) for lines `a` and `b` given boolean
  arrays `deleted` (over a) and `inserted` (over b), as produced by
  `diff.myers/edit-masks`. Within a changed region deletions come first."
  [a b ^booleans deleted ^booleans inserted]
  (let [av (vec a), bv (vec b)
        n (count av), m (count bv)]
    (loop [i 0, j 0, out (transient [])]
      (cond
        (and (== i n) (== j m)) (persistent! out)
        (and (< i n) (aget deleted i))
        (recur (inc i) j (conj! out [:delete (av i)]))
        (and (< j m) (aget inserted j))
        (recur i (inc j) (conj! out [:insert (bv j)]))
        :else ; both unmarked: a common line
        (recur (inc i) (inc j) (conj! out [:keep (av i)]))))))

(defn cost
  "Number of deletions plus insertions in `script`."
  [script]
  (count (remove #(= :keep (first %)) script)))

(defn apply-script
  "Applies `script` to the lines `a`, returning the resulting lines as a
  vector. Throws `ex-info` if the script is not valid for `a` (its keep and
  delete lines must be exactly `a`)."
  [a script]
  (let [av (vec a), n (count av)]
    (loop [s (seq script), i 0, out (transient [])]
      (if-let [[op line] (first s)]
        (case op
          :insert (recur (next s) i (conj! out line))
          (do
            (when-not (and (< i n) (= (av i) line))
              (throw (ex-info "Script does not match the original file"
                              {:script-line line :a-index i})))
            (recur (next s) (inc i)
                   (if (= op :keep) (conj! out line) out))))
        (do
          (when-not (== i n)
            (throw (ex-info "Script does not consume the whole original file"
                            {:consumed i :expected n})))
          (persistent! out))))))

(defn render
  "Renders `script` as text lines: each edit becomes its tag character
  followed by the line."
  [script]
  (mapv (fn [[op line]] (str (op->tag op) line)) script))

(defn parse
  "Parses rendered script lines (as produced by `render`) back into a script.
  Throws `ex-info` for a line that is empty or has an unknown tag."
  [lines]
  (mapv (fn [^String l]
          (let [op (when (pos? (.length l)) (tag->op (.charAt l 0)))]
            (when-not op
              (throw (ex-info "Invalid script line" {:line l})))
            [op (subs l 1)]))
        lines))
