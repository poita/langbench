(ns depresolve.index
  "Compiles a problem into the compact, array-based form used by the search.

  * Package names are interned to dense integer ids.
  * Each package's versions are sorted newest first and stored, encoded as
    `long`s (see `depresolve.version/encode`), in one flat array; `voff`
    holds each package's offset into it.
  * Every requirement becomes the triple `pkg, lo, hi` (stored flat in an
    `int[]` per package version): the candidates that satisfy it are exactly
    the version indices `lo` (inclusive) to `hi` (exclusive) in that package's
    newest-first order. They are found by binary search once, here, so the
    search never filters versions."
  (:require [depresolve.range :as range]
            [depresolve.version :as version])
  (:import (java.util ArrayList HashMap)))

(set! *warn-on-reflection* true)

(defrecord Index
  [names   ; String[]  package id -> name
   voff    ; int[]     package id -> offset of its first version (length n+1)
   vkeys   ; long[]    encoded versions, newest first within each package
   vreqs   ; Object[]  global version id -> int[] of requirement triples (or nil)
   root])  ; int[]     requirement triples of the root manifest (possibly empty)

(defn- first-below
  "Smallest index i in [from, to] such that vkeys[i] < x, or `to` if there is
  none. The segment [from, to) must be sorted in descending order."
  ^long [^longs vkeys ^long from ^long to ^long x]
  (loop [l from h to]
    (if (< l h)
      (let [m (unchecked-add l (bit-shift-right (unchecked-subtract h l) 1))]
        (if (< (aget vkeys m) x)
          (recur l m)
          (recur (unchecked-inc m) h)))
      l)))

(defn- ->range [r]
  (if (string? r) (range/parse r) r))

(defn- compile-requirements
  "Returns an int[] of `pkg lo hi` triples for the requirement list, or nil
  when it is empty."
  [^HashMap ids ^ints voff ^longs vkeys reqs]
  (when (seq reqs)
    (let [out (int-array (* 3 (count reqs)))]
      (loop [i 0 rs (seq reqs)]
        (when rs
          (let [{:keys [name range]} (first rs)
                id (long (.get ids name))
                from (aget voff id)
                to (aget voff (inc id))
                {:keys [lo hi]} (->range range)
                lo-key (version/encode lo)
                hi-key (if hi (version/encode hi) Long/MAX_VALUE)
                start (first-below vkeys from to hi-key)
                end (first-below vkeys from to lo-key)]
            (aset out i (unchecked-int id))
            (aset out (+ i 1) (unchecked-int (- start from)))
            (aset out (+ i 2) (unchecked-int (max (- end from) (- start from))))
            (recur (+ i 3) (next rs)))))
      out)))

(defn build
  "Builds an `Index` from a problem `{:registry [...] :root [...]}` (see
  `depresolve.input`). Requirement ranges may be range maps or range strings."
  [{:keys [registry root]}]
  (let [ids (HashMap.)
        names (ArrayList.)
        intern! (fn [^String n]
                  (or (.get ids n)
                      (let [id (.size names)]
                        (.add names n)
                        (.put ids n id)
                        id)))]
    (doseq [{:keys [name requirements]} registry]
      (intern! name)
      (doseq [r requirements] (intern! (:name r))))
    (doseq [r root] (intern! (:name r)))
    (let [n (.size names)
          by-pkg (object-array n)
          _ (doseq [e registry]
              (let [id (long (.get ids (:name e)))]
                (aset by-pkg id (cons e (aget by-pkg id)))))
          sorted (mapv (fn [es]
                         (vec (sort-by #(- (version/encode (:version %))) es)))
                       by-pkg)
          voff (int-array (inc n))
          _ (dotimes [i n]
              (aset voff (inc i) (unchecked-int (+ (aget voff i) (count (sorted i))))))
          total (aget voff n)
          vkeys (long-array total)
          vreqs (object-array total)
          _ (dotimes [i n]
              (let [off (aget voff i)]
                (dotimes [j (count (sorted i))]
                  (aset vkeys (+ off j)
                        (version/encode (:version ((sorted i) j)))))))]
      (dotimes [i n]
        (let [off (aget voff i)]
          (dotimes [j (count (sorted i))]
            (aset vreqs (+ off j)
                  (compile-requirements ids voff vkeys
                                        (:requirements ((sorted i) j)))))))
      (->Index (into-array String names)
               voff vkeys vreqs
               (or (compile-requirements ids voff vkeys root)
                   (int-array 0))))))
