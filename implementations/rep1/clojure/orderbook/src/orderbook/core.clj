(ns orderbook.core
  "Public API of the order book library.

  A limit order book for one instrument with price-time priority.  Create a
  book with [[new-book]], then drive it with [[execute!]] or the individual
  operations ([[limit-order!]], [[market-order!]], [[cancel-order!]],
  [[replace-order!]], [[snapshot]]).  Each operation returns a vector of
  *events* (see `orderbook.event`) describing what happened, in order.

      (require '[orderbook.core :as ob])
      (def book (ob/new-book))
      (ob/limit-order! book \"s1\" :sell 101 5)
      ;; => [{:event :rest, :id \"s1\"}]
      (ob/limit-order! book \"b1\" :buy 101 3)
      ;; => [{:event :trade, :taker \"b1\", :maker \"s1\", :price 101, :qty 3}
      ;;     {:event :filled, :id \"b1\"}]

  A book is mutable and not thread-safe: use one thread at a time.  Order
  ids are opaque strings; a LIMIT/MARKET whose id is currently resting is
  rejected.  Prices and quantities are positive longs (not validated)."
  (:require [orderbook.book :as book]
            [orderbook.engine :as engine]
            [orderbook.event :as event]))

(set! *warn-on-reflection* true)

(defn new-book
  "Returns a new, empty (mutable) order book."
  []
  (book/new-book))

(defn- collecting
  "Runs `(f sink)` and returns the events it emitted as a vector."
  [f]
  (let [out (java.util.ArrayList.)]
    (f #(.add out %))
    (vec out)))

(defn execute!
  "Executes a command map (see `orderbook.command`) against `book`.

  With two arguments returns the vector of events produced.  With a third
  argument `sink`, a function of one event, calls it with each event in
  order and returns nil (no intermediate collection is built)."
  ([book cmd] (collecting #(execute! book cmd %)))
  ([book cmd sink]
   (case (:op cmd)
     :limit (engine/limit! book (:id cmd) (:side cmd) (:price cmd) (:qty cmd)
                           (or (:tif cmd) :gtc) sink)
     :market (engine/market! book (:id cmd) (:side cmd) (:qty cmd) sink)
     :cancel (engine/cancel! book (:id cmd) sink)
     :replace (engine/replace! book (:id cmd) (:price cmd) (:qty cmd) sink)
     :book (engine/book! book sink)
     (throw (ex-info (str "Unknown command op: " (pr-str (:op cmd))) {:cmd cmd})))
   nil))

(defn limit-order!
  "Submits a limit order; `side` is `:buy`/`:sell`.  Options: `:tif` of
  `:gtc` (default; remainder rests), `:ioc` (remainder cancelled) or `:fok`
  (all-or-nothing)."
  [book id side price qty & {:keys [tif] :or {tif :gtc}}]
  (execute! book {:op :limit :id id :side side :price price :qty qty :tif tif}))

(defn market-order!
  "Submits a market order; any unfilled remainder is cancelled."
  [book id side qty]
  (execute! book {:op :market :id id :side side :qty qty}))

(defn cancel-order!
  "Cancels a resting order; REJECT event if it is not resting."
  [book id]
  (execute! book {:op :cancel :id id}))

(defn replace-order!
  "Sets a resting order's price and *remaining* quantity.  Keeps time
  priority only if the price is unchanged and the quantity not increased."
  [book id price qty]
  (execute! book {:op :replace :id id :price price :qty qty}))

(defn snapshot
  "The current book as `{:bids [...] :asks [...]}`, each a vector of
  `{:price :qty :orders}` maps, best price first."
  [book]
  {:bids (book/level-summaries book :buy)
   :asks (book/level-summaries book :sell)})

(defn order
  "The resting order with this id as `{:id :side :price :qty}`, or nil."
  [book id]
  (when-let [o (book/resting-order book id)]
    {:id id :side (.side ^orderbook.book.Order o)
     :price (.price ^orderbook.book.Order o)
     :qty (.remaining ^orderbook.book.Order o)}))

(def format-event
  "Text form of an event, e.g. `\"TRADE b1 s1 101 5\"`."
  event/format-event)
