(ns orderbook.book
  "Mutable data structures behind the matching engine.

  A [[Book]] holds two sides.  Each side is a `java.util.TreeMap` from price
  to [[Level]], ordered so that the *best* price is always the first entry
  (ascending for asks, descending for bids), so the best level is found and
  an emptied level removed in O(log P).  A level keeps its resting orders in
  a `LinkedHashMap` keyed by order id, which gives a FIFO queue with O(1)
  removal of an order from the middle, plus a running quantity total.  A
  `HashMap` from id to order serves CANCEL and REPLACE.

  Everything here is mutable and not thread-safe; use it through
  `orderbook.engine` / `orderbook.core`, which are the supported API."
  (:import (java.util Collections HashMap LinkedHashMap TreeMap)))

(set! *warn-on-reflection* true)

(definterface IRemaining
  (^long remaining [])
  (setRemaining [^long q]))

(deftype Level [^long price
                ^LinkedHashMap queue
                ^:unsynchronized-mutable ^long total]
  IRemaining
  (remaining [_] total)
  (setRemaining [_ q] (set! total q)))

(deftype Order [id side ^long price ^Level level
                ^:unsynchronized-mutable ^long qty]
  IRemaining
  (remaining [_] qty)
  (setRemaining [_ q] (set! qty q)))

(deftype Book [^TreeMap bids ^TreeMap asks ^HashMap orders])

(defn new-book
  "Returns a new, empty mutable book."
  ^Book []
  (Book. (TreeMap. (Collections/reverseOrder)) (TreeMap.) (HashMap.)))

(defn side-tree
  "The price-ordered map of `side` (`:buy` or `:sell`): best level first."
  ^TreeMap [^Book book side]
  (if (identical? side :buy) (.bids book) (.asks book)))

(defn opposite-tree
  "The price-ordered map of the side a `side` order trades against."
  ^TreeMap [^Book book side]
  (if (identical? side :buy) (.asks book) (.bids book)))

(defn resting-order
  "The resting [[Order]] with this id, or nil."
  ^Order [^Book book id]
  (.get ^HashMap (.orders book) id))

(defn add-order!
  "Rests a new order at the back of the queue at `price`, creating the level
  if needed.  The id must not already be resting."
  ^Order [^Book book id side price qty]
  (let [price (long price)
        qty (long qty)
        tree (side-tree book side)
        level (or (.get tree price)
                  (let [l (Level. price (LinkedHashMap.) 0)]
                    (.put tree price l)
                    l))
        ^Level level level
        order (Order. id side price level qty)]
    (.put ^LinkedHashMap (.queue level) id order)
    (.setRemaining level (+ (.remaining level) qty))
    (.put ^HashMap (.orders book) id order)
    order))

(defn remove-order!
  "Takes `order` out of the book (O(1) in its queue, O(log P) if its level
  becomes empty)."
  [^Book book ^Order order]
  (let [^Level level (.level order)
        ^LinkedHashMap queue (.queue level)]
    (.remove queue (.id order))
    (.remove ^HashMap (.orders book) (.id order))
    (.setRemaining level (- (.remaining level) (.remaining order)))
    (when (.isEmpty queue)
      (.remove (side-tree book (.side order)) (.price level)))
    nil))

(defn reduce-order!
  "Sets the remaining quantity of a resting order (keeping its queue
  position) and updates its level's total."
  [^Order order ^long new-qty]
  (let [^Level level (.level order)]
    (.setRemaining level (+ (.remaining level) (- new-qty (.remaining order))))
    (.setRemaining order new-qty)
    nil))

(defn level-summaries
  "Vector of `{:price :qty :orders}` maps for one side, best price first."
  [^Book book side]
  (let [out (java.util.ArrayList.)]
    (doseq [^Level l (.values (side-tree book side))]
      (.add out {:price (.price l)
                 :qty (.remaining l)
                 :orders (.size ^LinkedHashMap (.queue l))}))
    (vec out)))
