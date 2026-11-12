(ns depresolve.core
  "Public API of depresolve: deterministic dependency resolution.

  Data shapes
  -----------
  A *registry* is a map from package name to a map from version string
  (`\"MAJOR.MINOR.PATCH\"`) to that version's requirements:

      {\"a\" {\"1.0.0\" [[\"c\" \"^1.0.0\"]]}
       \"c\" {\"1.1.0\" [] \"1.3.0\" []}}

  A *requirement* is a `[package-name range-string]` pair; a *manifest* (the
  root) is a vector of requirements, in order.  Range strings are `*`,
  `1.2.3`, `^1.2.3`, `~1.2.3` or space-separated comparators like
  `>=1.0.0 <2.0.0`.

  Resolution follows the specified search exactly: requirements are
  processed depth-first in the order written, candidates are tried newest
  version first, and failure backtracks chronologically."
  (:require [depresolve.index :as index]
            [depresolve.parse :as parse]
            [depresolve.search :as search]
            [depresolve.version :as version]))

(set! *warn-on-reflection* true)

(defn resolve-deps
  "Resolves `root` (a manifest) against `registry`.  Returns a sorted map
  from package name to chosen version string, or `nil` when the requirements
  are unsatisfiable.  An empty map is a successful resolution of a manifest
  that needs nothing."
  [registry root]
  (let [idx    (index/build registry root)
        chosen (search/search idx)]
    (when chosen
      (let [^ints chosen chosen
            ^objects names (:names idx)
            ^objects vers (:versions idx)]
        (into (sorted-map)
              (for [i (range (alength chosen))
                    :let [c (aget chosen i)]
                    :when (>= c 0)]
                [(aget names i) (version/fmt (aget ^longs (aget vers i) c))]))))))

(defn format-resolution
  "Renders the result of `resolve-deps` as the CLI output text: one
  `name version` line per package in ascending name order, or
  `unsatisfiable\\n` for `nil`."
  ^String [resolution]
  (if (nil? resolution)
    "unsatisfiable\n"
    (let [sb (StringBuilder.)]
      (doseq [[n v] resolution]
        (.append sb ^String n) (.append sb \space) (.append sb ^String v) (.append sb \newline))
      (.toString sb))))

(defn resolve-text
  "Parses `input` (registry lines followed by a `root:` line) and returns
  the exact output text for it."
  ^String [^String input]
  (let [{:keys [registry root]} (parse/parse-input input)]
    (format-resolution (resolve-deps registry root))))
