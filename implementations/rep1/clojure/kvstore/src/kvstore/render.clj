(ns kvstore.render
  "Formatting of `results.txt` blocks (spec section 19)."
  (:require [clojure.string :as str]
            [kvstore.bytes :as b]
            [kvstore.value :as v]))

(set! *warn-on-reflection* true)

(defn render-key
  "A key (byte array) as a quoted, escaped string."
  [^bytes k]
  (v/render-string (b/from-utf8 k)))

(defn row-line
  "Payload line of a `scan`/`find` result: `\"key\" = document`."
  [^bytes k doc]
  (str (render-key k) " = " (v/render doc)))

(defn block
  "Format result block `k` (the 1-based line number) from a status string and
  payload lines; every line ends with LF."
  [k status lines]
  (let [sb (StringBuilder.)]
    (.append sb "[") (.append sb (long k)) (.append sb "] ") (.append sb ^String status) (.append sb \newline)
    (doseq [l lines]
      (.append sb "  ") (.append sb ^String l) (.append sb \newline))
    (.toString sb)))

(defn stat-lines
  "The nine payload lines of `stat`."
  [{:keys [pages free freehead docs root height commits indexes wal]}]
  [(str "pages " pages) (str "free " free) (str "freehead " freehead) (str "docs " docs)
   (str "root " root) (str "height " height) (str "commits " commits)
   (str "indexes " indexes) (str "wal " wal)])

(defn index-line [{:keys [slot path root entries]}]
  (str slot " " path " root " root " entries " entries))

(defn path-text [segments] (str/join "." segments))
