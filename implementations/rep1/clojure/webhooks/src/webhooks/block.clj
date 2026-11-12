(ns webhooks.block
  "Reading and validating a `simulate` block from a sequence of lines."
  (:require [webhooks.fields :as f]))

(def ^:const max-endpoints 64)
(def ^:const max-events 20000)

(defn- parse-endpoint [fields]
  (when (= 5 (count fields))
    (let [[_ ep-id secrets filter script] fields
          ep-id (f/name-token ep-id)
          secrets (f/secrets secrets)
          filter (f/filter-field filter)
          script (f/script script)]
      (when (and ep-id secrets filter script)
        {:id ep-id
         :keys secrets
         :filter (when (not= filter :all) filter)
         :script script}))))

(defn- parse-event [fields]
  (when (= 5 (count fields))
    (let [[_ ev-id ts type payload] fields
          ev-id (f/name-token ev-id)
          ts (f/int-field ts)
          type (f/name-token type)
          payload (f/hex-bytes payload)]
      (when (and ev-id ts type payload)
        {:id ev-id :timestamp ts :type type :payload payload}))))

(defn read-block
  "Consumes the lines of a simulate block from `lines` (a seq of non-blank
  strings, positioned just after the `simulate` line) up to and including the
  terminating `end` line, or to the end of input.

  Returns [block remaining-lines]. `block` is {:endpoints [...] :events [...]}
  (maps as taken by `webhooks.simulator/simulate`), or nil if the block is
  malformed."
  [lines]
  (loop [lines lines, endpoints [], events [], ids #{}, ev-ids #{}, valid? true]
    (if-let [line (first lines)]
      (let [more (rest lines)]
        (if (= line "end")
          [(when (and valid? (seq endpoints))
             {:endpoints endpoints :events events})
           more]
          (let [fields (f/split-fields line)
                cmd (first fields)]
            (cond
              (not valid?) (recur more endpoints events ids ev-ids false)

              (= cmd "endpoint")
              (let [ep (when (empty? events) (parse-endpoint fields))]
                (if (and ep (< (count endpoints) max-endpoints)
                         (not (ids (:id ep))))
                  (recur more (conj endpoints ep) events (conj ids (:id ep)) ev-ids true)
                  (recur more endpoints events ids ev-ids false)))

              (= cmd "event")
              (let [ev (parse-event fields)]
                (if (and ev (< (count events) max-events)
                         (not (ev-ids (:id ev))))
                  (recur more endpoints (conj events ev) ids (conj ev-ids (:id ev)) true)
                  (recur more endpoints events ids ev-ids false)))

              :else (recur more endpoints events ids ev-ids false)))))
      [nil nil])))
