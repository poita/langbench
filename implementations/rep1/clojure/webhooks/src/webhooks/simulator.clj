(ns webhooks.simulator
  "A deterministic webhook delivery simulator.

  Events are signed and delivered to every matching endpoint. Each delivery
  makes up to eight attempts on a fixed retry schedule, and responses come
  from a per-endpoint script instead of a network."
  (:require [webhooks.signature :as signature])
  (:import (java.util PriorityQueue Comparator)))

(set! *warn-on-reflection* true)
(set! *unchecked-math* :warn-on-boxed)

(def retry-delays
  "Seconds between attempt n and attempt n+1, for n = 1..7."
  [5 300 1800 7200 18000 36000 36000])

(def ^:const max-attempts
  "Maximum number of attempts per delivery (the first plus seven retries)."
  8)

(defn matches?
  "True if `endpoint` should receive `event`. An endpoint's :filter is nil for
  every event type, or a set of the event types it wants."
  [endpoint event]
  (let [f (:filter endpoint)]
    (or (nil? f) (contains? f (:type event)))))

(defn- create-deliveries
  "Deliveries in creation order: events in order, and for each the matching
  endpoints in order. Each delivery is signed here, once."
  [endpoints events]
  (let [eps (vec endpoints)]
    (into []
          (comp
           (mapcat (fn [event]
                     (let [id (:id event)
                           ts (str (:timestamp event))
                           body (:payload event)]
                       (for [[ei ep] (map-indexed vector eps)
                             :when (matches? ep event)]
                         {:event event
                          :endpoint-index ei
                          :header (signature/signature-header
                                   (:keys ep) id ts body)}))))
           (map-indexed (fn [n d] (assoc d :number n))))
          events)))

(defn- response-code
  "Converts a script entry (a status code or :timeout) to a long, with -1
  standing for a timeout."
  ^long [r]
  (if (= r :timeout) -1 (long r)))

(defn simulate
  "Runs a delivery simulation.

  `endpoints` is a sequence of maps with
    :id      string
    :keys    the endpoint's secret keys (byte arrays, see
             `webhooks.signature/parse-secret`)
    :filter  nil for all event types, or a set of event type strings
    :script  vector of responses: a status code (long) or :timeout; once
             exhausted the last response repeats
  `events` is a sequence of maps with
    :id string, :timestamp long (seconds), :type string, :payload byte array

  Returns
    {:attempts   [{:seq :event :endpoint :n :ts :outcome :code} ...]
     :deliveries [{:event :endpoint :status :attempts :last-ts :header} ...]}
  where attempts are in processing order and deliveries in creation order.
  :outcome is :success :failure :timeout or :gone; :code is nil for a timeout;
  :status is :delivered :failed or :disabled; :last-ts is nil if no attempt
  was made."
  [endpoints events]
  (let [eps (vec endpoints)
        deliveries (create-deliveries eps events)
        nd (count deliveries)
        scripts (object-array (map #(long-array (map response-code (:script %))) eps))
        cursors (long-array (count eps))
        disabled (boolean-array (count eps))
        next-time (long-array nd)
        made (long-array nd)        ; attempts made so far
        last-ts (long-array nd)
        status (object-array nd)
        queue (PriorityQueue.
               (max 1 nd)
               (reify Comparator
                 (compare [_ a b]
                   (let [ta (aget next-time (int a))
                         tb (aget next-time (int b))]
                     (cond (< ta tb) -1
                           (> ta tb) 1
                           :else (Integer/compare (int a) (int b)))))))
        attempts (volatile! (transient []))]
    (dotimes [d nd]
      (aset next-time d (long (:timestamp (:event (nth deliveries d)))))
      (.add queue (int d)))
    (loop [seq-no 1]
      (let [d (.poll queue)]
        (if (nil? d)
          seq-no
          (let [d (int d)
                {:keys [event endpoint-index]} (nth deliveries d)
                ei (int endpoint-index)
                t (aget next-time d)]
            (if (aget disabled ei)
              (do (aset status d :disabled)
                  (recur seq-no))
              (let [^longs script (aget scripts ei)
                    cur (aget cursors ei)
                    r (aget script (min cur (dec (alength script))))
                    n (inc (aget made d))
                    outcome (cond (= r -1) :timeout
                                  (<= 200 r 299) :success
                                  (= r 410) :gone
                                  :else :failure)]
                (aset cursors ei (inc cur))
                (aset made d n)
                (aset last-ts d t)
                (vswap! attempts conj!
                        {:seq seq-no
                         :event (:id event)
                         :endpoint (:id (nth eps ei))
                         :n n
                         :ts t
                         :outcome outcome
                         :code (when (not= r -1) r)})
                (case outcome
                  :success (aset status d :delivered)
                  :gone (do (aset status d :failed)
                            (aset disabled ei true))
                  (if (>= n max-attempts)
                    (aset status d :failed)
                    (do (aset next-time d (+ t (long (nth retry-delays (dec n)))))
                        (.add queue d))))
                (recur (inc seq-no))))))))
    {:attempts (persistent! @attempts)
     :deliveries
     (vec (map-indexed
           (fn [d delivery]
             (let [n (aget made d)]
               {:event (:id (:event delivery))
                :endpoint (:id (nth eps (:endpoint-index delivery)))
                :status (aget status d)
                :attempts n
                :last-ts (when (pos? n) (aget last-ts d))
                :header (:header delivery)}))
           deliveries))}))
