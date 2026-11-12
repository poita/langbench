(ns protowire.error
  "Error signalling shared by all protowire modules.

  Every failure caused by bad *input* (a malformed schema, wire data or text,
  or a value that does not fit its declared type) is an `ex-info` whose data
  map has `:type` set to `:protowire/error`. Use [[protowire-error?]] to test
  for it.")

(defn fail
  "Throws a protowire error with `msg` (and optional extra data map)."
  ([msg] (fail msg nil))
  ([msg data]
   (throw (ex-info (str msg) (assoc data :type :protowire/error)))))

(defn protowire-error?
  "True if `e` is an exception thrown by [[fail]]."
  [e]
  (and (instance? clojure.lang.ExceptionInfo e)
       (= :protowire/error (:type (ex-data e)))))
