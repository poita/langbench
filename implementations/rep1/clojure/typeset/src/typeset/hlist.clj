(ns typeset.hlist
  "Horizontal lists: turning units into BOX / GLUE / PENALTY items.

  An `hlist` is a map of parallel primitive arrays (`:kind` 0 box, 1 glue,
  2 penalty; widths, stretch, shrink, penalty values, flags and the width of
  each penalty's pre-break text) plus `:items`, a vector with one map per item
  carrying the text and face data of the boxes, and `:notes`, the footnotes
  referenced from the list."
  (:require [typeset.hyphenation :as hy]
            [typeset.inline :as inline]
            [typeset.metrics :as m]
            [typeset.util :as u :refer [scale]])
  (:import (java.util ArrayList IdentityHashMap)))

(set! *warn-on-reflection* true)

(def ^:const BOX 0)
(def ^:const GLUE 1)
(def ^:const PENALTY 2)

;; ---------------------------------------------------------------------------
;; Style resolution

(defn- step-size ^long [^long s op]
  (if (= op :up) (quot (* s 6) 5) (quot (* s 5) 6)))

(defn resolve-style
  "Resolve a unit style against context `ctx`: `[face-name family size]`."
  [ctx st]
  (let [fam (if (:m st) "mono" (:family ctx))
        bold (or (:bold ctx) (:b st))
        italic (or (:italic ctx) (:i st))
        size (reduce step-size (long (:size ctx)) (:ops st))]
    [(m/face-name fam bold italic) fam size]))

;; ---------------------------------------------------------------------------
;; Sentence ends

(def ^:private skip-set #{41 93 125 39 34 8217 8221})

(defn- char-unit? [x] (= :char (:k x)))
(defn- disc? [x] (= :disc (:k x)))

(defn sentence-end?
  "Whether the space at index `i` of `units` follows a sentence end."
  [units ^long i]
  (let [k (loop [k (dec i)]
            (if (neg? k)
              k
              (let [x (nth units k)]
                (if (or (disc? x) (and (char-unit? x) (skip-set (:c x))))
                  (recur (dec k))
                  k))))]
    (if (or (neg? k) (not (char-unit? (nth units k))) (not (#{46 33 63} (:c (nth units k)))))
      false
      (let [k2 (loop [k2 (dec k)]
                 (if (and (>= k2 0) (disc? (nth units k2))) (recur (dec k2)) k2))]
        (if (neg? k2)
          true
          (let [x (nth units k2)]
            (not (and (char-unit? x) (<= 65 (:c x) 90)))))))))

;; ---------------------------------------------------------------------------
;; Fragments and hyphenation

(defn- letter? [^long c] (or (<= 65 c 90) (<= 97 c 122)))

(defn- lower-letters ^String [^ints cps ^long from ^long to]
  (let [sb (StringBuilder.)]
    (loop [i from]
      (when (< i to)
        (let [c (aget cps i)]
          (.append sb (char (if (<= 65 c 90) (+ c 32) c))))
        (recur (inc i))))
    (str sb)))

(defn- fragment-points
  "Hyphenation points of a fragment: a sorted vector of `{:pos :pen :pre?}`
  (all points are flagged)."
  [{:keys [settings hyph]} ctx fam ^ints cps discs]
  (let [n (alength cps)
        lo (loop [i 0] (cond (>= i n) n (letter? (aget cps i)) i :else (recur (inc i))))]
    (if (or (not (:hyphenate ctx)) (not (settings "hyphenate")) (= fam "mono") (>= lo n))
      []
      (let [hi (loop [i (dec n)] (if (letter? (aget cps i)) (inc i) (recur (dec i))))
            ex-pen (settings "ex-hyphen-penalty")
            h-pen (settings "hyphen-penalty")
            core-hyphens (for [i (range lo hi) :when (== 45 (aget cps i))]
                           {:pos (inc i) :pen ex-pen :pre? false})
            explicit (distinct (filter #(< 0 % n) discs))
            pts (if (seq explicit)
                  (concat core-hyphens
                          (map (fn [p] {:pos p :pen h-pen :pre? true}) explicit))
                  (let [pset (hyph (settings "hyphen-patterns"))]
                    (concat
                     core-hyphens
                     (loop [s lo i lo out []]
                       (if (> i hi)
                         out
                         (if (or (== i hi) (== 45 (aget cps i)))
                           (let [all? (every? #(letter? (aget cps %)) (range s i))]
                             (recur (inc i) (inc i)
                                    (if (and all? (> i s))
                                      (into out (map (fn [q] {:pos (+ s q) :pen h-pen :pre? true})
                                                     (hy/breaks pset (lower-letters cps s i))))
                                      out)))
                           (recur s (inc i) out)))))))
            ;; dedupe by position keeping the first (core hyphens come first)
            by-pos (reduce (fn [mp p] (if (contains? mp (:pos p)) mp (assoc mp (:pos p) p)))
                           (sorted-map) pts)]
        (vec (vals by-pos))))))

(defn- emit-fragment!
  [^ArrayList items {:keys [faces] :as env} ctx {:keys [^ArrayList cps discs face size raise fam id]}]
  (let [cp-arr (int-array cps)
        n (alength cp-arr)
        fc (faces face)
        pts (fragment-points env ctx fam cp-arr discs)
        base {:face face :size size :raise raise :frag id}
        box (fn [from to]
              (.add items (assoc base :kind BOX :text (u/cps->str cp-arr from to)
                                 :w (m/box-width fc cp-arr from to size))))]
    (if (empty? pts)
      (box 0 n)
      (let [hyphen-w (m/string-width fc "-" size)]
        (loop [from 0 ps pts]
          (if-let [p (first ps)]
            (do (box from (:pos p))
                (.add items {:kind PENALTY :pen (:pen p) :flag true
                             :pre (when (:pre? p)
                                    (assoc base :kind BOX :text "-" :w hyphen-w))})
                (recur (long (:pos p)) (next ps)))
            (box from n)))))))

;; ---------------------------------------------------------------------------
;; Building

(defn- glue-item [fc size extra? ragged? ragged-stretch]
  (let [{:keys [space stretch shrink extra]} fc
        w (if extra? (scale (+ space extra) size) (scale space size))
        y (if extra? (scale (+ stretch (quot stretch 2)) size) (scale stretch size))
        z (scale shrink size)]
    (if ragged?
      {:kind GLUE :w w :y (* ragged-stretch w) :z 0 :inf false}
      {:kind GLUE :w w :y y :z z :inf false})))

(defn- to-arrays [items notes]
  (let [n (count items)
        kind (byte-array n) w (long-array n) y (long-array n) z (long-array n)
        inf (boolean-array n) pen (long-array n) flag (boolean-array n)
        pre (long-array n)]
    (dotimes [i n]
      (let [it (nth items i)]
        (case (long (:kind it))
          0 (do (aset kind i (byte BOX)) (aset w i (long (:w it))))
          1 (do (aset kind i (byte GLUE)) (aset w i (long (:w it)))
                (aset y i (long (:y it))) (aset z i (long (:z it)))
                (aset inf i (boolean (:inf it))))
          2 (do (aset kind i (byte PENALTY)) (aset pen i (long (:pen it)))
                (aset flag i (boolean (:flag it)))
                (when-let [p (:pre it)] (aset pre i (long (:w p))))))))
    {:n n :kind kind :w w :y y :z z :inf inf :pen pen :flag flag :pre pre
     :items items :notes notes}))

(defn build
  "Build the horizontal list of `units` (already whitespace-normalised) in
  context `ctx`. `env` supplies `:settings`, `:faces` and `:hyph`."
  [{:keys [settings faces] :as env} ctx units]
  (let [items (ArrayList.)
        notes (ArrayList.)
        units (vec units)
        cache (IdentityHashMap.)
        resolve (fn [st]
                  (or (.get cache st)
                      (let [r (resolve-style ctx st)] (.put cache st r) r)))
        ragged? (not= :justify (:align ctx))
        rs (settings "ragged-stretch")
        frag-id (long-array 1)
        next-id (fn [] (aset frag-id 0 (inc (aget frag-id 0))) (aget frag-id 0))
        cur (volatile! nil)
        flush! (fn []
                 (when-let [f @cur]
                   (emit-fragment! items env ctx f)
                   (vreset! cur nil)))
        n (count units)]
    (dotimes [i n]
      (let [x (nth units i)]
        (case (:k x)
          :char
          (let [[face fam size] (resolve (:st x))
                f @cur]
            (if (and f (= face (:face f)) (== size (:size f)) (zero? (:raise f)))
              (.add ^ArrayList (:cps f) (int (:c x)))
              (do (flush!)
                  (let [cps (ArrayList.)]
                    (.add cps (int (:c x)))
                    (vreset! cur {:cps cps :discs (ArrayList.) :face face :size size
                                  :raise 0 :fam fam :id (next-id)})))))
          :disc
          (when-let [f @cur]
            (.add ^ArrayList (:discs f) (long (.size ^ArrayList (:cps f)))))
          :space
          (do (flush!)
              (let [[face _ size] (resolve (:st x))
                    extra? (and (not (:plain x)) (sentence-end? units i))]
                (.add items (glue-item (faces face) size extra? ragged? rs))))
          :rigid
          (do (flush!)
              (let [[face _ size] (resolve (:st x))]
                (.add items {:kind BOX :w (scale (:space (faces face)) size)})))
          :gap
          (do (flush!) (.add items {:kind BOX :w (:w x)}))
          :note
          (do (flush!)
              (let [[_ fam _] (resolve (:st x))
                    face (m/face-name fam (or (:bold ctx) (:b (:st x))) (or (:italic ctx) (:i (:st x))))
                    size (settings "mark-size")
                    text (str (:n x))
                    cps (u/code-points text)]
                (.add notes {:n (:n x) :units (:units x)})
                (.add items {:kind BOX :text text :face face :size size
                             :raise (settings "mark-raise") :frag (next-id) :note (:n x)
                             :w (m/box-width (faces face) cps 0 (alength cps) size)}))))))
    (flush!)
    (.add items {:kind PENALTY :pen 10000 :flag false})
    (.add items {:kind GLUE :w 0 :y 0 :z 0 :inf true})
    (.add items {:kind PENALTY :pen -10000 :flag false})
    (to-arrays (vec items) (vec notes))))

(defn natural-width
  "Natural width of the whole list on one line (the infinite glue is 0)."
  ^long [{:keys [^longs w ^long n]}]
  (loop [i 0 acc 0] (if (< i n) (recur (inc i) (+ acc (aget w i))) acc)))

(defn breakpoints
  "Indices of the breakpoints of `hl` (not including the notional start)."
  [{:keys [^bytes kind ^longs pen ^long n]}]
  (loop [i 0 out (transient [])]
    (if (< i n)
      (let [k (aget kind i)]
        (recur (inc i)
               (if (or (and (== k GLUE) (pos? i) (== (aget kind (dec i)) BOX))
                       (and (== k PENALTY) (< (aget pen i) 10000)))
                 (conj! out i)
                 out)))
      (persistent! out))))
