(ns buildsys.graph
  "The dependency graph over steps, phony targets and source files.

  Nodes are small integers: steps are `0 .. S-1` (their serial numbers),
  phony targets follow, and source nodes (existing files that no step
  produces) are allocated as they are referenced.  Everything here is built in
  O(S + E)."
  (:require [buildsys.errors :as e]
            [buildsys.vfs :as vfs]))

(set! *warn-on-reflection* true)

(defn- claim-outputs
  "Maps every output path (declared outputs, then depfile) to its step serial.
  Throws `E_DUP_OUTPUT` for the first path claimed twice."
  [steps]
  (reduce (fn [m step]
            (reduce (fn [m p]
                      (if (contains? m p)
                        (e/fail! "E_DUP_OUTPUT" p)
                        (assoc m p (:serial step))))
                    m (:outputs step)))
          {} steps))

(defn- resolve-ref
  "Resolves reference `ref` to a node id, or nil.  `sources` is a volatile map
  path -> node id that grows as source nodes are discovered."
  [{:keys [out->step phony->id vfs sources next-id]} ^String ref]
  (if (.startsWith ref "@")
    (get phony->id (subs ref 1))
    (or (get out->step ref)
        (get @sources ref)
        (when (vfs/exists? vfs ref)
          (let [id @next-id]
            (vswap! next-id inc)
            (vswap! sources assoc ref id)
            id)))))

(defn- node-name [g id]
  (let [{:keys [steps phonies n-steps]} g]
    (cond (< id n-steps) (:primary (nth steps id))
          (< id (+ n-steps (count phonies))) (str "@" (:name (nth phonies (- id n-steps))))
          :else (get (:source-names g) id))))

(defn build
  "Validates the whole graph (duplicate outputs, then references in steps and
  phony targets, then the default list) and builds it.

  Returns {:steps :phonies :n-steps :succs [[id ...] ...] :names [name ...]
           :resolve (fn [ref] id-or-nil) :defaults [...]} where `:succs` is
  each node's ordering dependencies with duplicates removed."
  [{:keys [steps phonies defaults]} vfs]
  (let [n-steps (count steps)
        out->step (claim-outputs steps)
        phony->id (into {} (map-indexed (fn [i p] [(:name p) (+ n-steps i)])) phonies)
        g {:out->step out->step :phony->id phony->id :vfs vfs
           :sources (volatile! {}) :next-id (volatile! (+ n-steps (count phonies)))}
        res (fn [ref] (resolve-ref g ref))
        missing! (fn [ref owner] (e/fail! "E_MISSING_INPUT" (str ref " required by " owner)))
        step-deps (mapv (fn [step]
                          (mapv (fn [ref] (or (res ref) (missing! ref (:primary step))))
                                (concat (:ins step) (:afters step))))
                        steps)
        phony-deps (mapv (fn [p]
                           (mapv (fn [ref] (or (res ref) (missing! ref (str "@" (:name p)))))
                                 (:deps p)))
                         phonies)]
    (doseq [ref defaults]
      (when-not (res ref) (e/fail! "E_UNKNOWN_TARGET" ref)))
    (let [sources @(:sources g)
          source-names (into {} (map (fn [[p id]] [id p])) sources)
          total @(:next-id g)
          dedup (fn [ids] (vec (distinct ids)))
          succs (vec (concat (map dedup step-deps)
                             (map dedup phony-deps)
                             (repeat (count sources) [])))
          names (vec (concat (map :primary steps)
                             (map #(str "@" (:name %)) phonies)
                             (map #(get source-names %)
                                  (range (+ n-steps (count phonies)) total))))]
      {:steps steps :phonies phonies :n-steps n-steps :defaults defaults
       :succs succs :names names
       :resolve res})))

(defn resolve-targets
  "Resolves requested target strings to node ids, throwing
  `E_UNKNOWN_TARGET` for the first that resolves to nothing."
  [graph targets]
  (mapv (fn [t] (or ((:resolve graph) t) (e/fail! "E_UNKNOWN_TARGET" t))) targets))

(defn find-cycle-or-reach
  "Depth-first search from the requested nodes `roots` exactly as the
  specification describes.  Throws `E_CYCLE` with the cycle's node names, or
  returns the reachable node ids (those coloured grey or black)."
  [{:keys [succs names]} roots]
  (let [colour (java.util.HashMap.)    ; id -> :grey | :black ; absent = white
        reached (java.util.ArrayList.)]
    (doseq [root roots]
      (when-not (.containsKey colour root)
        (.put colour root :grey)
        (.add reached root)
        (loop [stack [[root 0]]]
          (when (seq stack)
            (let [[n i] (peek stack)
                  ss (nth succs n)]
              (if (< i (count ss))
                (let [m (nth ss i)
                      stack (conj (pop stack) [n (inc i)])
                      c (.get colour m)]
                  (cond
                    (= c :grey)
                    (let [j (first (keep-indexed (fn [k [id _]] (when (= id m) k)) stack))
                          path (concat (map (fn [[id _]] (nth names id)) (subvec stack j))
                                       [(nth names m)])]
                      (e/fail! "E_CYCLE" (clojure.string/join " -> " path)))
                    (nil? c)
                    (do (.put colour m :grey)
                        (.add reached m)
                        (recur (conj stack [m 0])))
                    :else (recur stack)))
                (do (.put colour n :black)
                    (recur (pop stack)))))))))
    (vec reached)))
