(ns buildsys.graph
  "The build graph: nodes, reference resolution, validation, cycle detection
  and reachability.

  Nodes are identified by: a long (a step's serial number), `\"@name\"` (a
  phony target) or a plain path string (a source file)."
  (:require [buildsys.error :as err]
            [buildsys.path :as path]
            [buildsys.vfs :as vfs]))

(set! *warn-on-reflection* true)

(defn node-name
  "The name of `node` as used in messages."
  [graph node]
  (if (integer? node)
    (:primary (nth (:steps graph) node))
    node))

(defn- resolve-ref
  "Resolve target reference `ref` to a node, or nil."
  [{:keys [phonies out-owner vfs]} ^String ref]
  (if (path/phony-ref? ref)
    (when (contains? phonies (subs ref 1)) ref)
    (or (get out-owner ref)
        (when (vfs/exists? vfs ref) ref))))

(defn build-graph
  "Validate the evaluated build (`{:steps :phonies :phony-order :defaults}`
  from [[buildsys.eval/evaluate]]) against file system `vfs`: duplicate
  outputs, then reference resolution, then the default list.  Returns the
  graph, or throws the first error."
  [{:keys [steps phonies phony-order defaults]} vfs]
  (let [out-owner (volatile! {})]
    (doseq [s steps, p (:full-outs s)]
      (when (contains? @out-owner p) (err/fail "E_DUP_OUTPUT" p))
      (vswap! out-owner assoc p (:serial s)))
    (let [g {:steps steps :phonies phonies :out-owner @out-owner :vfs vfs}
          resolve-all
          (fn [refs owner]
            (mapv (fn [r]
                    (or (resolve-ref g r)
                        (err/fail "E_MISSING_INPUT" (str r " required by " owner))))
                  refs))
          order-deps (vec (for [s steps]
                            (resolve-all (concat (:ins s) (:afters s)) (:primary s))))
          phony-deps (into {} (for [name phony-order]
                                [(str "@" name)
                                 (resolve-all (phonies name) (str "@" name))]))
          default-nodes (mapv #(or (resolve-ref g %) (err/fail "E_UNKNOWN_TARGET" %))
                              defaults)]
      (assoc g
             :order-deps order-deps
             :phony-deps phony-deps
             :defaults defaults
             :default-nodes default-nodes))))

(defn successors
  "The successor list of `node`: its ordering dependencies, duplicates removed
  keeping the first occurrence."
  [graph node]
  (cond
    (integer? node) (distinct (nth (:order-deps graph) node))
    (contains? (:phony-deps graph) node) (distinct (get (:phony-deps graph) node))
    :else []))

(defn requested-targets
  "Resolve the requested targets (`targets`, or the default list when empty)
  to nodes.  Throws `E_NO_DEFAULT` or `E_UNKNOWN_TARGET`."
  [graph targets]
  (let [names (distinct (if (seq targets) targets (:defaults graph)))]
    (when (empty? names) (err/fail "E_NO_DEFAULT"))
    (mapv #(or (resolve-ref graph %) (err/fail "E_UNKNOWN_TARGET" %)) names)))

(defn reachable
  "Search for cycles from `roots` with the specification's exact depth-first
  search.  Returns the set of reachable nodes, or throws `E_CYCLE`."
  [graph roots]
  (let [colour (java.util.HashMap.)]
    (doseq [root roots]
      (when-not (.containsKey colour root)
        (.put colour root :grey)
        (loop [stack [[root 0 (vec (successors graph root))]]]
          (when (seq stack)
            (let [[n i succ] (peek stack)]
              (if (< i (count succ))
                (let [m (nth succ i)
                      stack (conj (pop stack) [n (inc i) succ])
                      c (.get colour m)]
                  (cond
                    (= c :grey)
                    (let [j (first (keep-indexed (fn [k [x]] (when (= x m) k)) stack))
                          names (concat (map (fn [[x]] (node-name graph x)) (subvec stack j))
                                        [(node-name graph m)])]
                      (err/fail "E_CYCLE" (clojure.string/join " -> " names)))
                    (nil? c)
                    (do (.put colour m :grey)
                        (recur (conj stack [m 0 (vec (successors graph m))])))
                    :else (recur stack)))
                (do (.put colour n :black)
                    (recur (pop stack)))))))))
    (set (keys colour))))
