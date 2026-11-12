(ns orderbook.event
  "Events emitted by the engine: constructors and text rendering.

  An event is a plain map with an `:event` key:

  | `:event`    | other keys                                |
  |-------------|-------------------------------------------|
  | `:trade`    | `:taker :maker :price :qty`               |
  | `:rest`     | `:id`                                     |
  | `:cancel`   | `:id :qty` (unfilled quantity)            |
  | `:reject`   | `:id`                                     |
  | `:filled`   | `:id`                                     |
  | `:bid`      | `:price :qty :orders` (BOOK listing)      |
  | `:ask`      | `:price :qty :orders` (BOOK listing)      |
  | `:book-end` | (end of a BOOK listing)                   |")

(set! *warn-on-reflection* true)

(defn trade [taker maker price qty]
  {:event :trade :taker taker :maker maker :price price :qty qty})
(defn rest-event [id] {:event :rest :id id})
(defn cancel [id qty] {:event :cancel :id id :qty qty})
(defn reject [id] {:event :reject :id id})
(defn filled [id] {:event :filled :id id})
(defn bid [price qty orders] {:event :bid :price price :qty qty :orders orders})
(defn ask [price qty orders] {:event :ask :price price :qty qty :orders orders})
(def book-end {:event :book-end})

(defn append-event!
  "Appends the one-line text form of `ev` (without a newline) to the
  `Appendable` `out`, e.g. `TRADE b1 s1 101 5`."
  [^Appendable out ev]
  (case (:event ev)
    :trade (-> out
               (.append "TRADE ") (.append ^String (:taker ev))
               (.append " ") (.append ^String (:maker ev))
               (.append " ") (.append (Long/toString (:price ev)))
               (.append " ") (.append (Long/toString (:qty ev))))
    :rest (-> out (.append "REST ") (.append ^String (:id ev)))
    :cancel (-> out
                (.append "CANCEL ") (.append ^String (:id ev))
                (.append " ") (.append (Long/toString (:qty ev))))
    :reject (-> out (.append "REJECT ") (.append ^String (:id ev)))
    :filled (-> out (.append "FILLED ") (.append ^String (:id ev)))
    (:bid :ask) (-> out
                    (.append (if (identical? :bid (:event ev)) "BID " "ASK "))
                    (.append (Long/toString (:price ev)))
                    (.append " ") (.append (Long/toString (:qty ev)))
                    (.append " ") (.append (Long/toString (:orders ev))))
    :book-end (.append out "--"))
  nil)

(defn format-event
  "The one-line text form of an event, without a trailing newline."
  ^String [ev]
  (let [sb (StringBuilder.)]
    (append-event! sb ev)
    (.toString sb)))
