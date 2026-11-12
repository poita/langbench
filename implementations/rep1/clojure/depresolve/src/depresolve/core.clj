(ns depresolve.core
  "Public API of depresolve, a package dependency resolver.

  A *problem* is a registry (every version of every package with its
  requirements) plus a root manifest. `resolve-problem` returns the first
  complete resolution in the specified search order (depth-first, newest
  version first, chronological backtracking), or `nil` when none exists.

  Data shapes:

      requirement  {:name \"c\" :range \"^1.0.0\"}   ; range: string or parsed map
      registry     [{:name \"a\" :version [1 0 0] :requirements [requirement ...]} ...]
      problem      {:registry registry :root [requirement ...]}
      resolution   {\"a\" [1 0 0], \"c\" [1 2 5]}      ; package name -> version

  Versions are `[major minor patch]` vectors."
  (:require [clojure.string :as str]
            [depresolve.index :as index]
            [depresolve.input :as input]
            [depresolve.search :as search]
            [depresolve.version :as version]))

(set! *warn-on-reflection* true)

(defn parse-input
  "Parses the text format (registry lines followed by a `root:` line) into a
  problem map."
  [text]
  (input/parse text))

(defn resolve-problem
  "Resolves `problem`. Returns a sorted map of package name -> version vector
  for every package needed, or nil when the requirements are unsatisfiable. A
  root without requirements gives an empty map."
  [problem]
  (let [{:keys [^objects names ^longs vkeys ^ints voff] :as idx} (index/build problem)]
    (when-let [^ints chosen (search/solve idx)]
      (into (sorted-map)
            (keep (fn [^long pkg]
                    (let [c (aget chosen pkg)]
                      (when (>= c 0)
                        [(aget names pkg)
                         (version/decode (aget vkeys (+ (aget voff pkg) c)))]))))
            (range (alength names))))))

(defn format-resolution
  "Formats a resolution as the CLI output: one `name version` line per package
  in ascending name order, or `unsatisfiable` when `resolution` is nil."
  [resolution]
  (if (nil? resolution)
    "unsatisfiable\n"
    (str/join (for [[n v] (sort-by key resolution)]
                (str n " " (version/fmt v) "\n")))))

(defn resolve-text
  "Parses `text`, resolves it, and returns the formatted output string."
  [text]
  (format-resolution (resolve-problem (parse-input text))))
