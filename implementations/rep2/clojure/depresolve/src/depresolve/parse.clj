(ns depresolve.parse
  "Parser for the textual registry-and-root input format.

  The result is plain data (see `depresolve.core` for its shape):

      {:registry {\"a\" {\"1.0.0\" [[\"c\" \"^1.0.0\"]]}}
       :root     [[\"a\" \"*\"]]}"
  (:require [clojure.string :as str]))

(set! *warn-on-reflection* true)

(defn- parse-requirements
  "Parses the text after the colon (`\"\"` or `\" a ^1.0.0, b *\"`) into a
  vector of `[name range]` pairs in written order."
  [^String s]
  (if (.isEmpty s)
    []
    (let [parts (str/split (subs s 1) #", ")]
      (mapv (fn [^String r]
              (let [i (.indexOf r " ")]
                [(.substring r 0 i) (.substring r (unchecked-inc-int i))]))
            parts))))

(defn parse-input
  "Parses the whole input text.  Registry lines are `name version:reqs`, the
  final line is `root:reqs`.  Versions of a package are kept in a map from
  version string to requirement vector."
  [^String text]
  (loop [lines (str/split-lines text)
         registry (transient {})]
    (let [^String line (first lines)
          colon (.indexOf line ":")
          head  (.substring line 0 colon)
          reqs  (parse-requirements (.substring line (unchecked-inc-int colon)))]
      (if (= "root" head)
        {:registry (persistent! registry) :root reqs}
        (let [sp (.indexOf head " ")
              nm (.substring head 0 sp)
              ve (.substring head (unchecked-inc-int sp))]
          (recur (rest lines)
                 (assoc! registry nm (assoc (get registry nm {}) ve reqs))))))))
