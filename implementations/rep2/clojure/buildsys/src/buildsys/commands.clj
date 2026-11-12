(ns buildsys.commands
  "The sixteen built-in commands.

  `table` maps a command name to its signature (argument types, how many file
  inputs and outputs it takes, whether it needs a depfile, default cost) and
  its implementation.  An implementation is `(fn [args inputs vfs])` where
  `inputs` is the vector of input paths and `vfs` the workspace snapshot taken
  when the command started; it returns
    {:output byte-string, :depfile byte-string-or-nil, :deps [path ...]}
  or throws an execution error."
  (:require [buildsys.errors :as e]
            [buildsys.vfs :as vfs]
            [clojure.string :as str]
            [buildsys.builtins :as builtins])
  (:import (java.util HashSet)))

(set! *warn-on-reflection* true)

;; ------------------------------------------------------------------- lines

(defn split-lines
  "The lines of byte string `s`: split at every 0x0A, dropping one final empty
  piece; the empty string has no lines."
  [^String s]
  (let [n (.length s)]
    (if (zero? n)
      []
      (loop [start 0 acc (transient [])]
        (let [i (.indexOf s (int \newline) (int start))]
          (cond
            (neg? i) (persistent! (conj! acc (subs s start n)))
            (= (inc i) n) (persistent! (conj! acc (subs s start i)))
            :else (recur (inc i) (conj! acc (subs s start i)))))))))

(defn join-lines
  "Concatenates each line followed by a newline."
  ^String [lines]
  (let [sb (StringBuilder.)]
    (doseq [^String l lines] (.append sb l) (.append sb \newline))
    (str sb)))

(defn- file [vfs path] (vfs/content vfs path))

(defn- single [inputs vfs] (file vfs (nth inputs 0)))

(defn- ascii-map ^String [^String s upper?]
  (let [n (.length s) sb (StringBuilder. n)]
    (dotimes [i n]
      (let [c (.charAt s i)]
        (.append sb (cond (and upper? (<= (int \a) (int c) (int \z))) (char (- (int c) 32))
                          (and (not upper?) (<= (int \A) (int c) (int \Z))) (char (+ (int c) 32))
                          :else c))))
    (str sb)))

;; ------------------------------------------------------------- preprocess

(def ^:private need-prefix "@need ")

(defn- need-directive
  "The needed path if `line` is a need directive, else nil."
  [^String line]
  (when (and (.startsWith line need-prefix) (> (.length line) 6))
    (subs line 6)))

(defn- preprocess* [vfs primary]
  (let [out (StringBuilder.)
        found (HashSet.)
        stack (HashSet.)]
    (letfn [(expand [^String p]
              (.add stack p)
              (doseq [^String line (split-lines (file vfs p))]
                (if-let [q (need-directive line)]
                  (do (when-not (vfs/valid-path? q) (e/fail! "E_NEED_PATH" q))
                      (when-not (vfs/exists? vfs q)
                        (e/fail! "E_NEED_MISSING" (str q " needed by " p)))
                      (when (.contains stack q) (e/fail! "E_NEED_CYCLE" q))
                      (.add found q)
                      (expand q))
                  (do (.append out line) (.append out \newline))))
              (.remove stack p))]
      (expand primary))
    (let [deps (vec (sort (vec found)))]
      {:output (str out)
       :deps deps
       :depfile (str "kiln-deps 1\n" (apply str (map #(str "need " % "\n") deps)))})))

;; ------------------------------------------------------------------ table

(defn- text-command
  "A command that maps the single input's content to an output string."
  [f]
  (fn [args inputs vfs] {:output (f args (single inputs vfs))}))

(defn- line-command [f]
  (text-command (fn [args content] (join-lines (f args (split-lines content))))))

(defn- cmd
  [args lo hi depfile? cost run]
  {:args args :min-in lo :max-in hi :depfile? depfile? :cost cost :run run})

(def table
  {"write"         (cmd [:str] 0 0 false 1
                        (fn [[text] _ _] {:output text}))
   "copy"          (cmd [] 1 1 false 1 (text-command (fn [_ c] c)))
   "concat"        (cmd [] 1 nil false 2
                        (fn [_ inputs vfs]
                          {:output (apply str (map #(file vfs %) inputs))}))
   "upper"         (cmd [] 1 1 false 2 (text-command (fn [_ c] (ascii-map c true))))
   "lower"         (cmd [] 1 1 false 2 (text-command (fn [_ c] (ascii-map c false))))
   "grep"          (cmd [:str] 1 1 false 3
                        (line-command (fn [[needle] ls]
                                        (filter #(<= 0 (.indexOf ^String % ^String needle)) ls))))
   "replace"       (cmd [:str :str] 1 1 false 3
                        (text-command (fn [[from to] c] (builtins/replace-all c from to))))
   "sort_lines"    (cmd [] 1 1 false 4 (line-command (fn [_ ls] (sort ls))))
   "reverse_lines" (cmd [] 1 1 false 2 (line-command (fn [_ ls] (rseq (vec ls)))))
   "dedup"         (cmd [] 1 1 false 3
                        (line-command (fn [_ ls]
                                        (let [seen (HashSet.)]
                                          (filter #(.add seen %) ls)))))
   "number"        (cmd [] 1 1 false 2
                        (line-command (fn [_ ls] (map-indexed (fn [i l] (str (inc i) ": " l)) ls))))
   "indent"        (cmd [:int] 1 1 false 2
                        (line-command (fn [[n] ls]
                                        (let [pad (apply str (repeat n \space))]
                                          (map #(str pad %) ls)))))
   "wrap"          (cmd [:str :str] 1 1 false 1
                        (text-command (fn [[prefix suffix] c] (str prefix c suffix))))
   "count_lines"   (cmd [] 1 nil false 2
                        (fn [_ inputs vfs]
                          (let [counts (map #(count (split-lines (file vfs %))) inputs)]
                            {:output (join-lines
                                      (concat (map #(str %1 " " %2) counts inputs)
                                              [(str (reduce + counts) " total")]))})))
   "hash"          (cmd [] 1 nil false 3
                        (fn [_ inputs vfs]
                          {:output (join-lines (map #(str (vfs/content-hash vfs %) " " %) inputs))}))
   "preprocess"    (cmd [] 1 1 true 6
                        (fn [_ inputs vfs] (preprocess* vfs (nth inputs 0))))})

(defn known? [name] (contains? table name))

(defn type-token
  "The `expected` token of a command argument type keyword."
  [t] (case t :str "str" :int "int"))

;; ----------------------------------------------------------- shape checks

(defn check-shape!
  "Raises `E_CMD_SHAPE` unless `n-inputs` file inputs, `n-outputs` declared
  outputs and the presence of a depfile suit command `name`."
  [name n-inputs n-outputs has-depfile?]
  (let [{:keys [min-in max-in depfile?]} (table name)]
    (when-not (and (>= n-inputs min-in) (or (nil? max-in) (<= n-inputs max-in)))
      (e/fail! "E_CMD_SHAPE"
               (str name ": expected inputs " min-in "-" (if max-in max-in "N") ", got " n-inputs)))
    (when-not (= 1 n-outputs)
      (e/fail! "E_CMD_SHAPE" (str name ": expected outputs 1, got " n-outputs)))
    (when (and depfile? (not has-depfile?))
      (e/fail! "E_CMD_SHAPE" (str name ": depfile required")))
    (when (and has-depfile? (not depfile?))
      (e/fail! "E_CMD_SHAPE" (str name ": depfile not allowed")))))

(defn check-args!
  "Command-specific argument checks (`E_ARG cmd ...`)."
  [name args]
  (case name
    "replace" (when (empty? (nth args 0)) (e/fail! "E_ARG" "cmd replace: empty pattern"))
    "indent" (when (neg? (long (nth args 0))) (e/fail! "E_ARG" "cmd indent: negative"))
    nil))

;; ----------------------------------------------------- canonical rendering

(defn- escape-str ^String [^String s]
  (let [sb (StringBuilder.)]
    (dotimes [i (.length s)]
      (let [c (.charAt s i) b (int c)]
        (cond
          (= c \\) (.append sb "\\\\")
          (= c \") (.append sb "\\\"")
          (= b 10) (.append sb "\\n")
          (= b 9) (.append sb "\\t")
          (= b 13) (.append sb "\\r")
          (or (< b 0x20) (= b 0x7f)) (.append sb (format "\\x%02x" b))
          :else (.append sb c))))
    (str sb)))

(defn canonical
  "The canonical rendering `name(arg, arg, ...)` of a command invocation."
  [name args]
  (str name "("
       (str/join ", " (map #(if (string? %) (str "\"" (escape-str %) "\"") (str %)) args))
       ")"))

(defn run
  "Runs command `name` (see the namespace docstring for the contract)."
  [name args inputs vfs]
  ((:run (table name)) args inputs vfs))
