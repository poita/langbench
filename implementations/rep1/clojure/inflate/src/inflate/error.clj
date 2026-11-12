(ns inflate.error
  "The single kind of failure the decoder reports: a malformed stream.")

(defn malformed!
  "Throws an `ex-info` marking the DEFLATE stream as malformed. `msg` says how;
  the ex-data is `{:type :inflate/malformed}`."
  [msg]
  (throw (ex-info msg {:type :inflate/malformed})))

(defn malformed?
  "True if `e` is a Throwable raised by `malformed!`."
  [e]
  (and (instance? clojure.lang.ExceptionInfo e)
       (= :inflate/malformed (:type (ex-data e)))))
