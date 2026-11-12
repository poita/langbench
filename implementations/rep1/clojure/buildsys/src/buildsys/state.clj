(ns buildsys.state
  "The `.kiln-state` file: strict reader, canonical writer and the freshness
  decision.

  A state is a sorted map from primary output path to an entry
  `{:cmd s :ins [[path hash]...] :deps [[path hash]...] :outs [[path hash]...]}`."
  (:require [buildsys.path :as path]
            [buildsys.vfs :as vfs]))

(set! *warn-on-reflection* true)

(def state-path ".kiln-state")

(defn- parse-pair [rest]
  (when-let [[_ p h] (re-matches #"([^ ]+) ([0-9a-f]{16})" rest)]
    (when (path/workspace-path? p) [p h])))

(defn- parse-entries
  "Parse the lines after the header into a map, or nil when invalid."
  [lines]
  (loop [lines (seq lines) entries (sorted-map) cur nil]
    (if-not lines
      (when (nil? cur) entries)
      (let [^String l (first lines)
            more (next lines)]
        (cond
          (nil? cur)
          (when (.startsWith l "step ")
            (let [k (subs l 5)]
              (when (and (path/workspace-path? k) (not (contains? entries k)))
                (recur more entries {:key k :cmd nil :phase 0 :in [] :dep [] :out []}))))

          (nil? (:cmd cur))
          (when (and (.startsWith l "cmd ") (> (.length l) 4))
            (recur more entries (assoc cur :cmd (subs l 4) :phase 1)))

          (= l "end")
          (when (and (seq (:out cur)) (= (:key cur) (ffirst (:out cur))))
            (recur more
                   (assoc entries (:key cur) {:cmd (:cmd cur) :ins (:in cur)
                                              :deps (:dep cur) :outs (:out cur)})
                   nil))

          :else
          (let [[sec rank prefix] (cond (.startsWith l "in ") [:in 1 3]
                                        (.startsWith l "dep ") [:dep 2 4]
                                        (.startsWith l "out ") [:out 3 4])]
            (when (and sec (>= (long rank) (long (:phase cur))))
              (when-let [pr (parse-pair (subs l prefix))]
                (recur more entries (-> cur (update sec conj pr) (assoc :phase rank)))))))))))

(defn read-state
  "Parse the content of a state file (a byte string, or nil when the file is
  absent).  Any deviation from the format yields an empty state."
  [^String content]
  (or (when (and content (.endsWith content "\n"))
        (let [lines (.split content "\n" -1)
              n (alength lines)]
          (when (and (>= n 2) (= "kiln-state 1" (aget lines 0)))
            (parse-entries (java.util.Arrays/copyOfRange lines 1 (dec n))))))
      (sorted-map)))

(defn write-state
  "Render `entries` (a map from primary output to entry) as state file
  content, sorted by primary output path."
  [entries]
  (let [sb (StringBuilder. "kiln-state 1\n")
        line (fn [k [p h]] (.append sb k) (.append sb \space) (.append sb ^String p)
               (.append sb \space) (.append sb ^String h) (.append sb \newline))]
    (doseq [[k e] (into (sorted-map) entries)]
      (.append sb "step ") (.append sb ^String k) (.append sb \newline)
      (.append sb "cmd ") (.append sb ^String (:cmd e)) (.append sb \newline)
      (doseq [x (:ins e)] (line "in" x))
      (doseq [x (:deps e)] (line "dep" x))
      (doseq [x (:outs e)] (line "out" x))
      (.append sb "end\n"))
    (str sb)))

(defn- matches-recorded?
  "Does every recorded `[path hash]` pair equal the file system's content?"
  [vfs pairs]
  (every? (fn [[p h]] (= h (vfs/file-hash vfs p))) pairs))

(defn fresh?
  "Change detection: is `step` a cache hit, given state `entries` and file
  system `vfs`?  See SPEC.md, \"Change detection\"."
  [entries vfs {:keys [primary canon full-outs file-ins]}]
  (if-let [e (get entries primary)]
    (and (= (:cmd e) canon)
         (= (mapv first (:outs e)) full-outs)
         (= (mapv first (:ins e)) file-ins)
         (matches-recorded? vfs (:ins e))
         (matches-recorded? vfs (:deps e))
         (matches-recorded? vfs (:outs e)))
    false))

(defn entry-for
  "The state entry recording a successful execution `result` (from
  [[buildsys.commands/execute]]) of `step`, whose outputs have already been
  written to `vfs`."
  [{:keys [canon]} {:keys [outputs ins deps]} vfs]
  {:cmd canon
   :ins ins
   :deps deps
   :outs (mapv (fn [[p _]] [p (vfs/file-hash vfs p)]) outputs)})
