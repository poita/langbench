(ns orderbook.engine
  "Matching engine: price-time priority over a mutable `orderbook.book/Book`.

  Every operation takes a `sink`, a function called with each event (see
  `orderbook.event`) in output order.  Quantities and prices are `long`s;
  level totals and FOK availability are sums of longs and may exceed 2^32."
  (:require [orderbook.book :as book]
            [orderbook.event :as ev])
  (:import (java.util Iterator LinkedHashMap Map$Entry TreeMap)
           (orderbook.book Book Level Order)))

(set! *warn-on-reflection* true)

(def ^:private ^:const market-buy-limit Long/MAX_VALUE)
(def ^:private ^:const market-sell-limit 0)

(defn- crosses?
  [side ^long limit ^long price]
  (if (identical? side :buy) (<= price limit) (>= price limit)))

(defn- match!
  "Matches a taker against the opposite side while it crosses `limit`
  (Long/MAX_VALUE for a market BUY, 0 for a market SELL).  Emits TRADE and
  maker FILLED events and returns the taker's remaining quantity."
  [^Book b taker side limit qty sink]
  (let [^TreeMap opp (book/opposite-tree b side)
        limit (long limit)]
    (loop [rem (long qty)]
      (if (zero? rem)
        0
        (let [e (.firstEntry opp)]
          (if (nil? e)
            rem
            (let [^Level level (.getValue ^Map$Entry e)
                  price (.price level)]
              (if-not (crosses? side limit price)
                rem
                (let [^Order maker (.getValue ^Map$Entry (.firstEntry ^LinkedHashMap (.queue level)))
                      mq (.remaining maker)
                      t (min rem mq)]
                  (sink (ev/trade taker (.id maker) price t))
                  (if (== t mq)
                    (do (book/remove-order! b maker)
                        (sink (ev/filled (.id maker))))
                    (book/reduce-order! maker (- mq t)))
                  (recur (- rem t)))))))))))

(defn- available
  "Total quantity resting on the opposite side at prices crossing `limit`,
  counted only until it reaches `needed` (so the result is >= needed iff
  enough is available)."
  ^long [^Book b side ^long limit ^long needed]
  (let [^Iterator it (.iterator (.values (book/opposite-tree b side)))]
    (loop [sum 0]
      (if (and (< sum needed) (.hasNext it))
        (let [^Level l (.next it)]
          (if (crosses? side limit (.price l))
            (recur (+ sum (.remaining l)))
            sum))
        sum))))

(defn- finish-taker!
  "Emits the taker's final event; rests the remainder when `rest?`."
  [^Book b id side price rem rest? sink]
  (cond
    (zero? rem) (sink (ev/filled id))
    rest? (do (book/add-order! b id side price rem)
              (sink (ev/rest-event id)))
    :else (sink (ev/cancel id rem))))

(defn limit!
  "Submits a limit order.  `tif` is `:gtc` (rest the remainder), `:ioc`
  (cancel the remainder) or `:fok` (fill completely or reject).  An id that
  is already resting is rejected."
  [^Book b id side price qty tif sink]
  (cond
    (some? (book/resting-order b id)) (sink (ev/reject id))
    (and (identical? tif :fok) (< (available b side price qty) qty))
    (sink (ev/reject id))
    :else (finish-taker! b id side price
                         (match! b id side price qty sink)
                         (identical? tif :gtc) sink)))

(defn market!
  "Submits a market order; the remainder is cancelled, never rested."
  [^Book b id side qty sink]
  (if (some? (book/resting-order b id))
    (sink (ev/reject id))
    (let [limit (if (identical? side :buy) market-buy-limit market-sell-limit)]
      (finish-taker! b id side 0 (match! b id side limit qty sink) false sink))))

(defn cancel!
  "Cancels a resting order, or rejects when `id` is not resting."
  [^Book b id sink]
  (if-let [^Order o (book/resting-order b id)]
    (let [rem (.remaining o)]
      (book/remove-order! b o)
      (sink (ev/cancel id rem)))
    (sink (ev/reject id))))

(defn replace!
  "Replaces a resting order's price and remaining quantity.  Keeps queue
  priority when the price is unchanged and the quantity not increased;
  otherwise the order re-enters as a new plain limit order."
  [^Book b id price qty sink]
  (if-let [^Order o (book/resting-order b id)]
    (if (and (== price (.price o)) (<= qty (.remaining o)))
      (do (book/reduce-order! o qty)
          (sink (ev/rest-event id)))
      (let [side (.side o)]
        (book/remove-order! b o)
        (limit! b id side price qty :gtc sink)))
    (sink (ev/reject id))))

(defn book!
  "Emits the BOOK listing: bids best first, asks best first, then the end
  marker."
  [^Book b sink]
  (doseq [^Level l (.values (book/side-tree b :buy))]
    (sink (ev/bid (.price l) (.remaining l) (.size ^LinkedHashMap (.queue l)))))
  (doseq [^Level l (.values (book/side-tree b :sell))]
    (sink (ev/ask (.price l) (.remaining l) (.size ^LinkedHashMap (.queue l)))))
  (sink ev/book-end))
