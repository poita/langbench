(ns toml.error
  "Parse errors.  Every failure to read a TOML document is signalled with an
  `ex-info` whose data map carries `:toml/error true` plus the character
  offset (`:pos`) at which the problem was detected.")

(defn fail
  "Throws a TOML parse error with `msg`, detected at character offset `pos`."
  [^String msg pos]
  (throw (ex-info (str "TOML parse error: " msg)
                  {:toml/error true :reason msg :pos pos})))

(defn parse-error?
  "True when `e` is an exception thrown by the TOML reader for invalid input."
  [e]
  (boolean (:toml/error (ex-data e))))

(defn locate
  "Returns a copy of the parse error `e` that also carries the 1-based `:line`
  and `:column` (counted in characters) of its offset within `text`."
  [e ^String text]
  (let [{:keys [pos reason] :as data} (ex-data e)
        pos  (min (long pos) (.length text))
        line (inc (count (filter #(== (int %) 10) (subs text 0 pos))))
        col  (inc (- pos (inc (.lastIndexOf text 10 (dec pos)))))]
    (ex-info (str "TOML parse error: " reason " (line " line ", column " col ")")
             (assoc data :line line :column col)
             e)))
