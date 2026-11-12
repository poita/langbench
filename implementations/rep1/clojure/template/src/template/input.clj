(ns template.input
  "The stdin format of the command-line tool: a JSON context, a line `--`,
  then `=== name` headed template bodies."
  (:require [clojure.string :as str]
            [template.json :as json]))

(defn- malformed [msg] (throw (ex-info msg {:template/input true})))

(defn parse-input
  "Parse the whole input text. Returns
  `{:context LinkedHashMap, :main \"first-template-name\", :templates {name source}}`."
  [^String text]
  (let [lines (vec (.split text "\n" -1))
        sep (or (first (keep-indexed (fn [i l] (when (= l "--") i)) lines))
                (malformed "missing -- separator"))
        context (json/parse (str/join "\n" (subvec lines 0 sep)))
        lines (subvec lines (inc sep))
        ;; the last template loses one trailing LF
        lines (if (and (seq lines) (= "" (peek lines))) (pop lines) lines)
        headers (vec (keep-indexed (fn [i l] (when (.startsWith ^String l "=== ") i)) lines))]
    (when-not (instance? java.util.LinkedHashMap context) (malformed "context is not an object"))
    (when (empty? headers) (malformed "no templates"))
    (let [bounds (map vector headers (concat (rest headers) [(count lines)]))
          entries (mapv (fn [[h e]]
                          [(subs ^String (nth lines h) 4)
                           (str/join "\n" (subvec lines (inc h) e))])
                        bounds)]
      {:context context
       :main (nth (first entries) 0)
       :templates (into {} entries)})))
