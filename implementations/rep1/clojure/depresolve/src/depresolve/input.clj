(ns depresolve.input
  "Parser for the registry/manifest text format.

  The parsed form (a *problem*) is plain data:

      {:registry [{:name \"a\" :version [1 0 0]
                   :requirements [{:name \"c\" :range {:lo .. :hi ..}} ...]}
                  ...]
       :root     [{:name \"a\" :range ...} ...]}

  See `depresolve.range` for the range representation."
  (:require [clojure.string :as str]
            [depresolve.range :as range]
            [depresolve.version :as version]))

(set! *warn-on-reflection* true)

(defn- parse-requirements
  "Parses the text after the `:` of a line (empty, or \" req, req, ...\")."
  [^String s]
  (if (< (count s) 2)
    []
    (mapv (fn [^String req]
            (let [i (.indexOf req " ")]
              {:name (subs req 0 i)
               :range (range/parse (subs req (inc i)))}))
          (str/split (subs s 1) #", "))))

(defn parse-line
  "Parses one line (without its newline). Returns `{:root [...]}` for the root
  line and `{:name .. :version .. :requirements [...]}` for a registry line."
  [^String line]
  (let [colon (.indexOf line ":")
        head (subs line 0 colon)
        reqs (parse-requirements (subs line (inc colon)))]
    (if (= head "root")
      {:root reqs}
      (let [sp (.indexOf head " ")]
        {:name (subs head 0 sp)
         :version (version/parse (subs head (inc sp)))
         :requirements reqs}))))

(defn parse
  "Parses the whole input text into a problem map (see the namespace doc).
  The input is assumed to be well formed; the last non-empty line is the root."
  [^String text]
  (let [parsed (->> (str/split-lines text)
                    (remove str/blank?)
                    (map parse-line))
        root (:root (last parsed))]
    {:registry (vec (butlast parsed))
     :root (or root [])}))
