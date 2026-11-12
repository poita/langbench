(ns buildsys.commands
  "The sixteen built-in commands.

  Each command has a signature (argument types, number of file inputs, number
  of outputs, whether it takes a depfile), a default cost, and an
  implementation.  [[execute]] runs a step's command against a file system
  snapshot and returns what to write; nothing is ever executed by a shell."
  (:require [buildsys.error :as err]
            [buildsys.hash :as hash]
            [buildsys.path :as path]
            [buildsys.vfs :as vfs])
  (:import (java.util HashSet)))

(set! *warn-on-reflection* true)

(defn split-lines
  "The lines of byte string `c`: none for \"\", otherwise the pieces between
  `\\n` bytes, dropping a final empty piece."
  [^String c]
  (let [n (.length c)]
    (if (zero? n)
      []
      (loop [from 0 out (transient [])]
        (let [i (.indexOf c (int \newline) (int from))]
          (cond
            (neg? i) (persistent! (conj! out (subs c from)))
            (= (inc i) n) (persistent! (conj! out (subs c from i)))
            :else (recur (inc i) (conj! out (subs c from i)))))))))

(defn join-lines
  "Concatenate `lines`, each followed by a newline."
  ^String [lines]
  (let [sb (StringBuilder.)]
    (doseq [^String l lines] (.append sb l) (.append sb \newline))
    (str sb)))

(defn- ascii-case [^String s upper?]
  (let [n (.length s) sb (StringBuilder. n)
        [lo hi d] (if upper? [\a \z -32] [\A \Z 32])]
    (dotimes [i n]
      (let [c (.charAt s i)]
        (.append sb (if (<= (int lo) (int c) (int hi)) (char (+ (int c) (int d))) c))))
    (str sb)))

(defn- need-line [^String l]
  (when (and (.startsWith l "@need ") (> (.length l) 6))
    (subs l 6)))

(defn- preprocess
  "Expand `@need` directives starting at `primary`.  Returns
  `[output-content discovered-paths-sorted]`."
  [vfs primary]
  (let [out (StringBuilder.)
        found (HashSet.)]
    (letfn [(expand [p stack]
              (let [stack (conj stack p)]
                (doseq [^String l (split-lines (vfs/content vfs p))]
                  (if-let [q (need-line l)]
                    (do (when-not (path/workspace-path? q)
                          (err/fail "E_NEED_PATH" q))
                        (when-not (vfs/exists? vfs q)
                          (err/fail "E_NEED_MISSING" (str q " needed by " p)))
                        (when (contains? stack q)
                          (err/fail "E_NEED_CYCLE" q))
                        (.add found q)
                        (expand q stack))
                    (do (.append out l) (.append out \newline))))))]
      (expand primary #{}))
    [(str out) (vec (sort (vec found)))]))

(defn- wrap-lines [f] (fn [{:keys [inputs]}] (join-lines (f (split-lines (first inputs))))))

(def commands
  "Command table, keyed by name.  `:params` are the argument types, `:inputs`
  is `[lo hi display]` (`hi` nil meaning unbounded), `:depfile` is true when a
  depfile is required and false when forbidden, `:cost` the default cost and
  `:run` the implementation: `(fn [{:keys [args inputs paths vfs]}])` returning
  the output content."
  {"write" {:params [:str] :inputs [0 0 "0-0"] :cost 1
            :run (fn [{:keys [args]}] (first args))}
   "copy" {:params [] :inputs [1 1 "1-1"] :cost 1
           :run (fn [{:keys [inputs]}] (first inputs))}
   "concat" {:params [] :inputs [1 nil "1-N"] :cost 2
             :run (fn [{:keys [inputs]}] (apply str inputs))}
   "upper" {:params [] :inputs [1 1 "1-1"] :cost 2
            :run (fn [{:keys [inputs]}] (ascii-case (first inputs) true))}
   "lower" {:params [] :inputs [1 1 "1-1"] :cost 2
            :run (fn [{:keys [inputs]}] (ascii-case (first inputs) false))}
   "grep" {:params [:str] :inputs [1 1 "1-1"] :cost 3
           :run (fn [{:keys [args inputs]}]
                  (let [^String needle (first args)]
                    (join-lines (filter (fn [^String l] (.contains l needle))
                                        (split-lines (first inputs))))))}
   "replace" {:params [:str :str] :inputs [1 1 "1-1"] :cost 3
              :run (fn [{:keys [args inputs]}]
                     (let [^String s (first inputs)]
                       (.replace s ^String (first args) ^String (second args))))}
   "sort_lines" {:params [] :inputs [1 1 "1-1"] :cost 4
                 :run (wrap-lines #(sort %))}
   "reverse_lines" {:params [] :inputs [1 1 "1-1"] :cost 2
                    :run (wrap-lines reverse)}
   "dedup" {:params [] :inputs [1 1 "1-1"] :cost 3
            :run (wrap-lines (fn [ls] (distinct ls)))}
   "number" {:params [] :inputs [1 1 "1-1"] :cost 2
             :run (wrap-lines (fn [ls] (map-indexed (fn [i l] (str (inc i) ": " l)) ls)))}
   "indent" {:params [:int] :inputs [1 1 "1-1"] :cost 2
             :run (fn [{:keys [args inputs]}]
                    (let [pad (apply str (repeat (first args) \space))]
                      (join-lines (map #(str pad %) (split-lines (first inputs))))))}
   "wrap" {:params [:str :str] :inputs [1 1 "1-1"] :cost 1
           :run (fn [{:keys [args inputs]}] (str (first args) (first inputs) (second args)))}
   "count_lines" {:params [] :inputs [1 nil "1-N"] :cost 2
                  :run (fn [{:keys [inputs paths]}]
                         (let [counts (map (comp count split-lines) inputs)]
                           (join-lines (concat (map #(str %1 " " %2) counts paths)
                                               [(str (reduce + counts) " total")]))))}
   "hash" {:params [] :inputs [1 nil "1-N"] :cost 3
           :run (fn [{:keys [inputs paths]}]
                  (join-lines (map #(str (hash/hash-hex %1) " " %2) inputs paths)))}
   "preprocess" {:params [] :inputs [1 1 "1-1"] :cost 6 :depfile true}})

(defn lookup
  "The command spec for `name`, or nil."
  [name]
  (get commands name))

(defn- escape-string [^String s]
  (let [sb (StringBuilder. "\"")]
    (doseq [c s]
      (let [i (int c)]
        (cond
          (= c \\) (.append sb "\\\\")
          (= c \") (.append sb "\\\"")
          (= c \newline) (.append sb "\\n")
          (= c \tab) (.append sb "\\t")
          (= c \return) (.append sb "\\r")
          (or (< i 0x20) (= i 0x7f)) (.append sb (format "\\x%02x" i))
          :else (.append sb c))))
    (.append sb \")
    (str sb)))

(defn canonical
  "The canonical rendering of a command: `name(arg, arg, ...)`."
  [name args]
  (str name "("
       (clojure.string/join ", " (map #(if (string? %) (escape-string %) (str %)) args))
       ")"))

(defn validate-args
  "Command-specific argument checks (`E_ARG cmd ...`)."
  [name args]
  (case name
    "replace" (when (= "" (first args))
                (err/fail "E_ARG" "cmd replace: empty pattern"))
    "indent" (when (neg? (first args))
               (err/fail "E_ARG" "cmd indent: negative"))
    nil))

(defn execute
  "Run `step` (a map with `:cmd`, `:args`, `:file-ins`, `:outs`, `:depfile`)
  against the file system snapshot `vfs`.  Returns
  `{:outputs [[path content] ...] :ins [[path hash] ...] :deps [[path hash] ...]}`
  or throws a Kiln execution error."
  [{:keys [cmd args file-ins outs depfile]} vfs]
  (let [spec (commands cmd)
        inputs (mapv #(or (vfs/content vfs %) "") file-ins)
        ins (mapv (fn [p] [p (vfs/file-hash vfs p)]) file-ins)]
    (if (:depfile spec)
      (let [[out discovered] (preprocess vfs (first file-ins))]
        {:outputs [[(first outs) out]
                   [depfile (str "kiln-deps 1\n"
                                 (apply str (map #(str "need " % "\n") discovered)))]]
         :ins ins
         :deps (mapv (fn [p] [p (vfs/file-hash vfs p)]) discovered)})
      {:outputs [[(first outs) ((:run spec) {:args args :inputs inputs
                                             :paths file-ins :vfs vfs})]]
       :ins ins
       :deps []})))
