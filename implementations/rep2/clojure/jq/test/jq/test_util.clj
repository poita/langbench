(ns jq.test-util
  "Helpers shared by the test namespaces."
  (:require [jq.core :as jq]))

(defn q
  "Runs `filter` on the JSON text `doc`; returns a vector of output JSON texts."
  [filter doc]
  (jq/query filter doc))

(defn q+
  "Like [[q]] but, when evaluation fails, returns the outputs so far followed by
  the string \"error\" — the CLI's view of the world."
  [filter doc]
  (try (jq/query filter doc)
       (catch clojure.lang.ExceptionInfo e
         (if (jq/error? e)
           (conj (mapv jq/write-json (:outputs (ex-data e))) "error")
           (throw e)))))
