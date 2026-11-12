(ns depresolve.index
  "Compiles registry data into the compact, array-based index the search
  runs on.

  * Every package name is interned to a dense integer id.
  * The versions of each package are sorted newest first, as packed `long`s.
  * Every requirement is turned into a `Req`: the target package id plus the
    contiguous half-open index range `[from, to)` of the target's
    newest-first version array that its range admits (found by binary
    search, once).  Candidates during the search are exactly those indices,
    and \"does the chosen version satisfy this requirement\" is a range check
    on the chosen index."
  (:require [depresolve.range :as range]
            [depresolve.version :as v]))

(set! *warn-on-reflection* true)

(deftype Req [^int pkg ^int from ^int to])

(defrecord Index
  [^objects names    ; id -> package name (String)
   ^objects versions ; id -> long[] of packed versions, newest first
   ^objects reqs     ; id -> Object[] (per version index) of Object[] of Req
   ^objects root])   ; Req[] of the root manifest, in written order

(defn- count-geq
  "Number of elements of the descending `long[]` `arr` that are >= `x`."
  ^long [^longs arr ^long x]
  (loop [lo 0 hi (alength arr)]
    (if (< lo hi)
      (let [mid (unsigned-bit-shift-right (+ lo hi) 1)]
        (if (>= (aget arr mid) x)
          (recur (inc mid) hi)
          (recur lo mid)))
      lo)))

(defn- compile-req
  [^java.util.HashMap ids ^objects versions [^String nm ^String rng]]
  (let [id  (int (.get ids nm))
        arr ^longs (aget versions id)
        [lo hi] (range/parse rng)
        [from to] (if (< ^long lo ^long hi)
                    [(count-geq arr hi) (count-geq arr lo)]
                    [0 0])]
    (Req. id (int from) (int to))))

(defn build
  "Builds an `Index` from `registry` (`{name {version-string [[name range]
  ...]}}`) and `root` (`[[name range] ...]`).  Packages mentioned only in
  requirements get an id and an empty version array."
  [registry root]
  (let [all-names (into (sorted-set)
                        (concat (keys registry)
                                (map first root)
                                (for [vs (vals registry), reqs (vals vs), [n _] reqs] n)))
        n         (count all-names)
        ids       (java.util.HashMap. (* 2 (int n)))
        names     (object-array n)
        versions  (object-array n)
        sorted-vs (object-array n)]
    (doseq [[i nm] (map-indexed vector all-names)]
      (.put ids nm (int i))
      (aset names i nm)
      (let [vs (sort-by first #(compare ^long %2 ^long %1)
                        (map (fn [[s r]] [(v/parse s) r]) (get registry nm)))]
        (aset versions i (long-array (map first vs)))
        (aset sorted-vs i (mapv second vs))))
    (let [reqs (object-array n)]
      (dotimes [i n]
        (aset reqs i
              (object-array
               (map (fn [rs] (object-array (map #(compile-req ids versions %) rs)))
                    (aget sorted-vs i)))))
      (->Index names versions reqs
               (object-array (map #(compile-req ids versions %) root))))))
