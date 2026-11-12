(ns typeset.table
  "Table layout: cell measurement, column widths and rows."
  (:require [typeset.hlist :as hlist]
            [typeset.linebreak :as lb]
            [typeset.text :as text]
            [typeset.util :as u :refer [fdiv]]))

(set! *warn-on-reflection* true)

(defn- column-widths
  "Column widths from per-column natural and minimum widths."
  [nat minw measure gap]
  (let [cols (count nat)
        a (max 0 (- measure (* (dec cols) gap)))
        sum-nat (reduce + nat)
        sum-min (reduce + minw)]
    (cond
      (<= sum-nat a) (vec nat)
      (>= sum-min a) (vec minw)
      :else
      (let [d (- sum-nat a)
            s (reduce + (map - nat minw))]
        (loop [i 0 p 0 c-prev 0 out []]
          (if (< i cols)
            (let [p (long (+ p (- (nat i) (minw i))))
                  c (fdiv (* d p) s)]
              (recur (inc i) p c (conj out (- (nat i) (- c c-prev)))))
            out))))))

(def ^:private letter-align {\l :left \r :right \c :center})

(defn layout
  "Lay out table block `blk` in context `ctx`. Returns the vector of vertical
  items (`ROW`, `GLUE` and `RULE` maps)."
  [env ctx {:keys [cols aligns elements]}]
  (let [settings (:settings env)
        gap (long (settings "table-col-gap"))
        tl (long (settings "table-leading"))
        cell-ctx (fn [i] (assoc ctx :bold false :italic false :leading tl
                                :align (letter-align (nth aligns i))))
        ;; build every cell's list once
        built (mapv (fn [el]
                      (when (map? el)
                        (vec (map-indexed (fn [i units] (hlist/build env (cell-ctx i) units))
                                          (:row el)))))
                    elements)
        rows (keep identity built)
        measures (for [r rows] (mapv (fn [hl] [(hlist/natural-width hl)
                                               (lb/min-width hl (hlist/breakpoints hl))])
                                     r))
        nat (vec (for [i (range cols)] (reduce max 0 (map #(first (nth % i)) measures))))
        minw (vec (for [i (range cols)] (reduce max 0 (map #(second (nth % i)) measures))))
        widths (column-widths nat minw (:measure ctx) gap)
        tw (+ (reduce + widths) (* (dec cols) gap))
        xs (vec (reductions + (:left ctx) (map #(+ % gap) (butlast widths))))
        last-idx (dec (count elements))]
    (loop [idx 0 prev-row? false out []]
      (if (> idx last-idx)
        out
        (let [el (nth elements idx)]
          (if (map? el)
            (let [row (nth built idx)
                  cells (vec (map-indexed
                              (fn [i hl]
                                (let [c (assoc (cell-ctx i) :left (xs i)
                                               :measure (text/clamp-measure (widths i)))]
                                  (text/break-and-set env c hl 0)))
                              row))
                  a-row (reduce max (map #(long (:ascent (first %))) cells))
                  n-row (reduce max (map count cells))
                  d-row (reduce max (map #(long (:depth (peek %))) cells))
                  lines (vec (for [cell cells
                                   [k ln] (map-indexed vector cell)]
                               {:dy (+ a-row (* k tl)) :runs (:runs ln)}))
                  height (+ a-row (* (dec n-row) tl) d-row)]
              (recur (inc idx) true
                     (cond-> out
                       prev-row? (conj {:t :glue :h (settings "table-row-space")})
                       true (conj {:t :row :height height :lines lines}))))
            (let [rs (settings "table-rule-space")]
              (recur (inc idx) false
                     (cond-> out
                       (pos? idx) (conj {:t :glue :h rs})
                       true (conj {:t :rule :x (:left ctx) :w tw
                                   :thick (settings "table-rule-thickness")})
                       (< idx last-idx) (conj {:t :glue :h rs}))))))))))
