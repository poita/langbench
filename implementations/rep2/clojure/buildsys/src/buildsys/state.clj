(ns buildsys.state
  "The `.kiln-state` file: a strict reader, a canonical writer, and the
  freshness decision.

  In memory the state is a map from primary output path to an entry
    {:cmd string, :in [[path hash] ...], :dep [[path hash] ...], :out [[path hash] ...]}"
  (:require [buildsys.vfs :as vfs]
            [clojure.string :as str]))

(set! *warn-on-reflection* true)

(def header "kiln-state 1")

;; ----------------------------------------------------------------- reading

(defn- hex-hash? [^String s]
  (and (= 16 (.length s))
       (every? #(or (<= (int \0) (int %) (int \9)) (<= (int \a) (int %) (int \f))) s)))

(defn- path-hash
  "Parses `<path> <hash>` or returns nil."
  [^String s]
  (let [i (.indexOf s " ")]
    (when (and (pos? i) (= i (.lastIndexOf s " ")))
      (let [p (subs s 0 i) hh (subs s (inc i))]
        (when (and (vfs/valid-path? p) (hex-hash? hh)) [p hh])))))

(defn- split-state-lines [^String content]
  ;; content is known to end with a newline
  (let [n (.length content)]
    (loop [start 0 acc (transient [])]
      (if (>= start n)
        (persistent! acc)
        (let [i (.indexOf content (int \newline) (int start))]
          (recur (inc i) (conj! acc (subs content start i))))))))

(def ^:private section-order {:in 0 :dep 1 :out 2})
(def ^:private section-prefix {:in "in " :dep "dep " :out "out "})

(defn- section-of [^String l]
  (some (fn [[k ^String pre]] (when (.startsWith l pre) k)) section-prefix))

(defn- read-body
  "Reads `in`/`dep`/`out` lines up to `end`.  Returns [sections rest] or nil."
  [lines]
  (loop [ls lines current :in acc {:in [] :dep [] :out []}]
    (let [^String l (first ls)]
      (cond
        (nil? l) nil
        (= l "end") [acc (next ls)]
        :else
        (when-let [kind (section-of l)]
          (when-let [ph (path-hash (subs l (count (section-prefix kind))))]
            (when (<= (section-order current) (section-order kind))
              (recur (next ls) kind (update acc kind conj ph)))))))))

(defn- read-entry
  "Reads one entry from `lines` (a seq starting at its `step` line).  Returns
  [key entry rest-lines] or nil when malformed."
  [lines]
  (let [^String l0 (first lines)
        ^String l1 (second lines)]
    (when (and l0 l1 (.startsWith l0 "step ") (.startsWith l1 "cmd ") (> (.length l1) 4))
      (let [key (subs l0 5)]
        (when (vfs/valid-path? key)
          (when-let [[acc more] (read-body (nnext lines))]
            (when (and (seq (:out acc)) (= key (first (first (:out acc)))))
              [key (assoc acc :cmd (subs l1 4)) more])))))))

(defn parse
  "Parses the content of a state file.  A file that deviates from the grammar in
  any way is taken to be empty: returns {} in that case."
  [content]
  (if (and content
           (.endsWith ^String content "\n")
           (let [lines (split-state-lines content)] (= header (first lines))))
    (let [lines (rest (split-state-lines content))]
      (loop [ls (seq lines) m {}]
        (if (nil? ls)
          m
          (if-let [[k entry more] (read-entry ls)]
            (if (contains? m k) {} (recur more (assoc m k entry)))
            {}))))
    {}))

;; ----------------------------------------------------------------- writing

(defn render
  "The canonical text of state map `entries` (sorted by primary output)."
  [entries]
  (let [sb (StringBuilder.)]
    (.append sb header) (.append sb \newline)
    (doseq [[key {:keys [cmd in dep out]}] (sort-by key entries)]
      (.append sb "step ") (.append sb ^String key) (.append sb \newline)
      (.append sb "cmd ") (.append sb ^String cmd) (.append sb \newline)
      (doseq [[kind xs] [["in " in] ["dep " dep] ["out " out]]
              [p hh] xs]
        (.append sb ^String kind) (.append sb ^String p) (.append sb \space)
        (.append sb ^String hh) (.append sb \newline))
      (.append sb "end\n"))
    (str sb)))

;; --------------------------------------------------------------- freshness

(defn stale?
  "Decides whether `step` must run, given its state `entry` (or nil) and the
  current workspace.  See the 'Change detection' rules."
  [entry step vfs]
  (or (nil? entry)
      (not= (:cmd entry) (:cmd-str step))
      (not= (mapv first (:out entry)) (:outputs step))
      (not= (mapv first (:in entry)) (:file-ins step))
      (not-every? (fn [[p hh]] (= hh (vfs/content-hash vfs p)))
                  (concat (:in entry) (:dep entry) (:out entry)))))
