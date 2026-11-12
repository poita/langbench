(ns spreadsheet.graph
  "Graph algorithms used for incremental recalculation. Both are iterative so
  that dependency chains thousands of cells deep do not overflow the stack."
  (:import (java.util ArrayDeque ArrayList HashMap HashSet Iterator)))

(defn affected
  "Returns a vector of every cell id reachable from `id` (inclusive) by
  following the reverse-dependency map `rdeps` (`{id #{reader-ids}}`)."
  [rdeps id]
  (let [seen (HashSet.)
        out (ArrayList.)
        todo (ArrayDeque.)]
    (.add seen id)
    (.add todo id)
    (loop []
      (when-let [v (.poll todo)]
        (.add out v)
        (doseq [w (get rdeps v)]
          (when (.add seen w) (.add todo w)))
        (recur)))
    (vec out)))

(defn components
  "Tarjan's strongly-connected-components algorithm over the subgraph induced
  by the vector of node ids `ids`. `deps-of` maps a node id to the set of ids
  it depends on (edges to nodes outside `ids` are ignored).

  Returns a vector of `[members cyclic?]`, one per component, with each
  component emitted after every component it depends on. A component is
  cyclic if it has several members or its single member depends on itself."
  [ids deps-of]
  (let [n (count ids)
        id-at (long-array ids)
        local (HashMap. (* 2 n))
        _ (dotimes [i n] (.put local (aget id-at i) (long i)))
        index (long-array n -1)
        low (long-array n)
        on-stack (boolean-array n)
        iters (object-array n)
        scc-stack (long-array n)
        call-stack (long-array n)
        out (transient [])
        counter (volatile! 0)
        sp (volatile! 0)
        cp (volatile! 0)
        visit! (fn [^long v]
                 (let [c (long @counter)]
                   (aset index v c)
                   (aset low v c)
                   (vreset! counter (inc c)))
                 (aset scc-stack (long @sp) v)
                 (vswap! sp inc)
                 (aset on-stack v true)
                 (aset iters v (when-let [d (deps-of (aget id-at v))] (.iterator ^Iterable d)))
                 (aset call-stack (long @cp) v)
                 (vswap! cp inc))
        pop-component!
        (fn [^long v]
          (loop [members (transient [])]
            (vswap! sp dec)
            (let [w (aget scc-stack (long @sp))]
              (aset on-stack w false)
              (let [members (conj! members (aget id-at w))]
                (if (== w v)
                  (let [m (persistent! members)
                        vid (aget id-at v)]
                    (conj! out [m (or (> (count m) 1)
                                      (boolean (some-> (deps-of vid) (contains? vid))))]))
                  (recur members))))))]
    (dotimes [root n]
      (when (== -1 (aget index root))
        (visit! root)
        (while (pos? (long @cp))
          (let [v (aget call-stack (dec (long @cp)))
                ^Iterator it (aget iters v)]
            (if (and it (.hasNext it))
              (let [w (.get local (.next it))]
                (when w
                  (let [w (long w)]
                    (cond
                      (== -1 (aget index w)) (visit! w)
                      (aget on-stack w) (aset low v (min (aget low v) (aget index w)))))))
              (do
                (vswap! cp dec)
                (when (== (aget low v) (aget index v))
                  (pop-component! v))
                (when (pos? (long @cp))
                  (let [p (aget call-stack (dec (long @cp)))]
                    (aset low p (min (aget low p) (aget low v)))))))))))
    (persistent! out)))
