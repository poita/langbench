(ns typeset.vlist
  "Vertical lists: the flat sequence of vertical items, the space registers
  and the baseline rule shared by pages, footnote stacks and figures.

  A vertical item is a map with a `:t` of `:line`, `:glue`, `:rule`, `:row`,
  `:floatmark` or `:forcebreak`."
  (:import (java.util ArrayList)))

(set! *warn-on-reflection* true)

(defmacro baseline
  "Baseline of the next line: `fresh` is true at the top of a stack (after
  anything that is not a line). A macro so that the result stays a primitive
  `long` in the callers' loops."
  [fresh cursor prev-baseline prev-depth ascent leading line-skip]
  `(let [fresh# ~fresh cursor# (long ~cursor) pb# (long ~prev-baseline) pd# (long ~prev-depth)
         asc# (long ~ascent) lead# (long ~leading) skip# (long ~line-skip)]
     (if fresh#
       (+ cursor# asc#)
       (+ pb# (max lead# (+ pd# skip# asc#))))))

(defn stack-lines
  "Baselines of `lines` stacked from `top` (a fresh stack). Returns
  `{:baselines [...] :end cursor}`."
  [lines top line-skip]
  (loop [ls (seq lines) cursor (long top) fresh true pb 0 pd 0 out []]
    (if ls
      (let [{:keys [ascent depth leading]} (first ls)
            bl (baseline fresh cursor pb pd ascent leading line-skip)]
        (recur (next ls) (+ bl (long depth)) false bl (long depth) (conj out bl)))
      {:baselines out :end cursor})))

;; ---------------------------------------------------------------------------
;; The builder with the pending-space registers

(defn create
  "A fresh vertical list builder."
  []
  {:items (ArrayList.) :sp (long-array 3) :gid (long-array 1)})

(defn add! [vl item] (.add ^ArrayList (:items vl) item) item)

(defn items [vl] (vec ^ArrayList (:items vl)))

(defn pmax!
  "`pending-max = max(pending-max, v)`."
  [vl v]
  (let [^longs sp (:sp vl)] (aset sp 0 (max (aget sp 0) (long v)))))

(defn padd! [vl v]
  (let [^longs sp (:sp vl)] (aset sp 1 (+ (aget sp 1) (long v)))))

(defn reset-registers! [vl]
  (let [^longs sp (:sp vl)] (aset sp 0 0) (aset sp 1 0)))

(defn mark-started! [vl] (aset ^longs (:sp vl) 2 1))

(defn leaf!
  "Apply the space rules around a leaf block with the given space before and
  after; `emit` is called to add the block's own items."
  [vl before after emit]
  (let [^longs sp (:sp vl)]
    (pmax! vl before)
    (let [h (+ (aget sp 0) (aget sp 1))]
      (when (and (== 1 (aget sp 2)) (pos? h))
        (.add ^ArrayList (:items vl) {:t :glue :h h})))
    (aset sp 0 (long after))
    (aset sp 1 0)
    (emit)
    (aset sp 2 1)))

(defn next-gid! [vl]
  (let [^longs g (:gid vl)] (aset g 0 (inc (aget g 0))) (aget g 0)))

(defn add-group!
  "Append `lines` as the `:line` items of one group of kind `kind`; `extra`
  is merged into every item and `first-extra` into the first only."
  [vl lines kind extra first-extra]
  (let [gid (next-gid! vl) n (count lines)]
    (doseq [[k ln] (map-indexed vector lines)]
      (.add ^ArrayList (:items vl)
            (cond-> (merge {:t :line :runs (:runs ln) :ascent (:ascent ln) :depth (:depth ln)
                            :leading (:leading ln) :notes (:notes ln)
                            :gid gid :k (inc k) :n n :kind kind}
                           extra)
              (zero? k) (merge first-extra))))))
