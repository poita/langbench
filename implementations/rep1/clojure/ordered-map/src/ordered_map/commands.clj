(ns ordered-map.commands
  "The line-oriented command language: parsing a command line and applying
  it to an ordered map, producing the textual response.

  See the README for the full command table."
  (:require [clojure.string :as str]
            [ordered-map.core :as om]))

(set! *warn-on-reflection* true)

(defn- key->str ^String [k] (if (nil? k) "missing" (Long/toString (long k))))

(defn- append-range!
  "Appends the keys in [lo, hi], space-separated, to `sb`; `empty` if none."
  [^StringBuilder sb m ^long lo ^long hi]
  (let [start (.length sb)]
    (om/reduce-keys (fn [^StringBuilder sb k]
                      (when (> (.length sb) start) (.append sb \space))
                      (.append sb (long k)))
                    sb m lo hi)
    (when (= start (.length sb)) (.append sb "empty"))))

(defn execute
  "Applies one command line to map `m`. Appends the response line (with a
  trailing newline) to `sb` and returns the new map."
  [m ^String line ^StringBuilder sb]
  (let [parts (str/split line #" " 3)
        cmd   (nth parts 0)
        arg1  #(Long/parseLong (nth parts 1))
        arg2  #(Long/parseLong (nth parts 2))
        reply (fn [^String s] (.append sb s) (.append sb \newline))
        m'    (case cmd
                "insert" (let [k (arg1) before (om/count m)
                               m' (om/insert m k (nth parts 2))]
                           (reply (if (= before (om/count m')) "updated" "ok"))
                           m')
                "delete" (let [k (arg1) m' (om/delete m k)]
                           (reply (if (identical? m m') "missing" "ok"))
                           m')
                "range"  (do (append-range! sb m (arg1) (arg2))
                             (.append sb \newline)
                             m)
                (do
                  (reply
                   (case cmd
                     "get"    (om/get m (arg1) "missing")
                     "size"   (Long/toString (om/count m))
                     "min"    (if-let [k (om/min-key m)] (key->str k) "empty")
                     "max"    (if-let [k (om/max-key m)] (key->str k) "empty")
                     "floor"  (key->str (om/floor m (arg1)))
                     "ceil"   (key->str (om/ceil m (arg1)))
                     "succ"   (key->str (om/succ m (arg1)))
                     "pred"   (key->str (om/pred m (arg1)))
                     "rank"   (Long/toString (om/rank m (arg1)))
                     "select" (key->str (om/select m (arg1)))
                     (throw (ex-info "unknown command" {:line line}))))
                  m))]
    m'))

(defn run
  "Runs the commands in `lines` (a seq of strings, without the leading count
  line) against an empty map, returning the whole output as a string."
  ^String [lines]
  (let [sb (StringBuilder.)]
    (reduce (fn [m line] (execute m line sb)) (om/ordered-map) lines)
    (.toString sb)))

(defn run-input
  "Runs a complete input document: the first line is the command count Q,
  followed by Q command lines. Returns the output as a string."
  ^String [^String input]
  (let [lines (str/split-lines input)
        q     (if (seq lines) (Long/parseLong (str/trim (first lines))) 0)]
    (run (take q (rest lines)))))
