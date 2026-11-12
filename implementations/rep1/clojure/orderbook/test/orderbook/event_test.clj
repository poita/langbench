(ns orderbook.event-test
  (:require [clojure.test :refer [deftest are]]
            [orderbook.event :as ev]))

(deftest formats-events
  (are [text event] (= text (ev/format-event event))
    "TRADE b1 s1 101 5" (ev/trade "b1" "s1" 101 5)
    "REST a" (ev/rest-event "a")
    "CANCEL a 3" (ev/cancel "a" 3)
    "REJECT a" (ev/reject "a")
    "FILLED a" (ev/filled "a")
    "BID 10 5000000000 2" (ev/bid 10 5000000000 2)
    "ASK 11 1 1" (ev/ask 11 1 1)
    "--" ev/book-end))
