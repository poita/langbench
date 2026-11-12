(ns orderbook.core-test
  (:require [clojure.test :refer [deftest is testing]]
            [orderbook.core :as ob]))

(defn- lines
  "Runs commands (a seq of maps) and returns all event lines."
  [book & cmds]
  (mapv ob/format-event (mapcat #(ob/execute! book %) cmds)))

(defn- run [& ops]
  (let [b (ob/new-book)]
    (vec (mapcat (fn [[f & args]] (map ob/format-event (apply f b args))) ops))))

(deftest rest-and-trade
  (let [b (ob/new-book)]
    (is (= [{:event :rest :id "s1"}] (ob/limit-order! b "s1" :sell 101 5)))
    (is (= [{:event :trade :taker "b1" :maker "s1" :price 101 :qty 3}
            {:event :filled :id "b1"}]
           (ob/limit-order! b "b1" :buy 101 3)))
    (is (= {:bids [] :asks [{:price 101 :qty 2 :orders 1}]} (ob/snapshot b)))
    (is (= {:id "s1" :side :sell :price 101 :qty 2} (ob/order b "s1")))))

(deftest price-time-priority
  (is (= ["REST b1" "REST b2" "REST b3" "REST b4"
          "TRADE s 1" "TRADE s 2"]
         (let [b (ob/new-book)]
           (concat
            (map ob/format-event
                 (concat (ob/limit-order! b "b1" :buy 100 5)
                         (ob/limit-order! b "b2" :buy 100 5)
                         (ob/limit-order! b "b3" :buy 100 5)
                         (ob/limit-order! b "b4" :buy 101 2)))
            ;; SELL 100 x 7 hits b4 (best price), then b1 (earliest)
            (map (fn [e] (str "TRADE s " (if (= "b4" (:maker e)) 1 2)))
                 (filter #(= :trade (:event %))
                         (ob/limit-order! b "s" :sell 100 7))))))))

(deftest maker-price-and-price-improvement
  (is (= ["REST s1" "REST s2"
          "TRADE b s1 101 5" "FILLED s1" "TRADE b s2 103 2" "FILLED b"]
         (run [ob/limit-order! "s1" :sell 101 5]
              [ob/limit-order! "s2" :sell 103 5]
              [ob/limit-order! "b" :buy 110 7]))))

(deftest ioc
  (is (= ["REST s1" "TRADE b s1 100 5" "FILLED s1" "CANCEL b 3" "CANCEL c 8"]
         (run [ob/limit-order! "s1" :sell 100 5]
              [ob/limit-order! "b" :buy 100 8 :tif :ioc]
              [ob/limit-order! "c" :buy 99 8 :tif :ioc])))
  (testing "an IOC remainder never rests"
    (let [b (ob/new-book)]
      (ob/limit-order! b "b" :buy 100 8 :tif :ioc)
      (is (= {:bids [] :asks []} (ob/snapshot b))))))

(deftest fok
  (testing "rejected without side effects when liquidity is short"
    (let [b (ob/new-book)]
      (ob/limit-order! b "s1" :sell 100 5)
      (ob/limit-order! b "s2" :sell 102 5)
      (is (= ["REJECT f"] (map ob/format-event (ob/limit-order! b "f" :buy 101 6 :tif :fok))))
      (is (= [{:price 100 :qty 5 :orders 1} {:price 102 :qty 5 :orders 1}]
             (:asks (ob/snapshot b))))
      (testing "exact quantity fills"
        (is (= ["TRADE f2 s1 100 5" "FILLED s1" "TRADE f2 s2 102 1" "FILLED f2"]
               (map ob/format-event (ob/limit-order! b "f2" :buy 102 6 :tif :fok))))))))

(deftest fok-sum-exceeds-32-bits
  (let [b (ob/new-book)]
    (dotimes [i 5] (ob/limit-order! b (str "s" i) :sell (+ 100 i) 1000000000))
    (is (= [:filled] (map :event (take-last 1 (ob/limit-order! b "f" :buy 200 5000000000 :tif :fok)))))
    (is (= {:bids [] :asks []} (ob/snapshot b)))
    (dotimes [i 5] (ob/limit-order! b (str "t" i) :sell 100 1000000000))
    (is (= [{:price 100 :qty 5000000000 :orders 5}] (:asks (ob/snapshot b))))))

(deftest market
  (is (= ["CANCEL m 4"] (run [ob/market-order! "m" :buy 4])))
  (is (= ["REST s1" "REST s2"
          "TRADE m s1 100 5" "FILLED s1" "TRADE m s2 101 1" "FILLED m"
          "TRADE n s2 101 4" "FILLED s2" "CANCEL n 4"]
         (run [ob/limit-order! "s1" :sell 100 5]
              [ob/limit-order! "s2" :sell 101 5]
              [ob/market-order! "m" :buy 6]
              [ob/market-order! "n" :buy 8]))))

(deftest cancel
  (is (= ["REST a" "CANCEL a 5" "REJECT a" "REJECT zzz"]
         (run [ob/limit-order! "a" :buy 10 5]
              [ob/cancel-order! "a"]
              [ob/cancel-order! "a"]
              [ob/cancel-order! "zzz"])))
  (testing "reports the remaining quantity of a partly filled order"
    (is (= ["REST a" "TRADE s a 10 2" "FILLED s" "CANCEL a 3"]
           (run [ob/limit-order! "a" :buy 10 5]
                [ob/limit-order! "s" :sell 10 2]
                [ob/cancel-order! "a"]))))
  (testing "filled and never-rested orders are not cancellable"
    (is (= ["REST a" "TRADE m a 10 5" "FILLED a" "FILLED m" "REJECT a" "REJECT m"]
           (run [ob/limit-order! "a" :buy 10 5]
                [ob/market-order! "m" :sell 5]
                [ob/cancel-order! "a"]
                [ob/cancel-order! "m"])))))

(deftest replace-orders
  (testing "decrease keeps priority"
    (let [b (ob/new-book)]
      (ob/limit-order! b "a" :buy 100 5)
      (ob/limit-order! b "c" :buy 100 5)
      (is (= ["REST a"] (map ob/format-event (ob/replace-order! b "a" 100 2))))
      (is (= ["TRADE s a 100 2" "FILLED a" "TRADE s c 100 1" "FILLED s"]
             (map ob/format-event (ob/limit-order! b "s" :sell 100 3))))))
  (testing "increase loses priority"
    (let [b (ob/new-book)]
      (ob/limit-order! b "a" :buy 100 5)
      (ob/limit-order! b "c" :buy 100 5)
      (is (= ["REST a"] (map ob/format-event (ob/replace-order! b "a" 100 6))))
      (is (= ["TRADE s c 100 5" "FILLED c" "TRADE s a 100 1" "FILLED s"]
             (map ob/format-event (ob/limit-order! b "s" :sell 100 6))))))
  (testing "same quantity keeps priority"
    (let [b (ob/new-book)]
      (ob/limit-order! b "a" :buy 100 5)
      (ob/limit-order! b "c" :buy 100 5)
      (ob/replace-order! b "a" 100 5)
      (is (= "TRADE s a 100 5" (ob/format-event (first (ob/limit-order! b "s" :sell 100 5)))))))
  (testing "price change loses priority even when quantity decreases"
    (let [b (ob/new-book)]
      (ob/limit-order! b "c" :buy 100 5)
      (ob/limit-order! b "a" :buy 99 5)
      (ob/replace-order! b "a" 100 1)
      (is (= [{:price 100 :qty 6 :orders 2}] (:bids (ob/snapshot b))))
      (is (= "TRADE s c 100 5" (ob/format-event (first (ob/limit-order! b "s" :sell 100 5)))))))
  (testing "aggressive replace trades against orders that arrived later"
    (is (= ["REST b1" "REST s1" "REST s2"
            "TRADE b1 s1 105 4" "FILLED s1" "REST b1"]
           (run [ob/limit-order! "b1" :buy 100 10]
                [ob/limit-order! "s1" :sell 105 4]
                [ob/limit-order! "s2" :sell 106 4]
                [ob/replace-order! "b1" 105 6]))))
  (testing "rejects ids that are not resting, and the order stays replaceable"
    (is (= ["REJECT x" "REST a" "REST a" "REST a" "CANCEL a 7"]
           (run [ob/replace-order! "x" 1 1]
                [ob/limit-order! "a" :sell 10 5]
                [ob/replace-order! "a" 11 6]
                [ob/replace-order! "a" 11 7]
                [ob/cancel-order! "a"])))))

(deftest book-listing
  (is (= ["--"] (run [ob/execute! {:op :book}])))
  (is (= ["REST a" "REST b" "REST c" "REST d"
          "BID 10 7 2" "BID 9 1 1" "ASK 11 4 1" "--"]
         (run [ob/limit-order! "a" :buy 10 3]
              [ob/limit-order! "b" :buy 9 1]
              [ob/limit-order! "c" :buy 10 4]
              [ob/limit-order! "d" :sell 11 4]
              [ob/execute! {:op :book}]))))

(deftest ids-are-opaque
  (is (= ["REST BUY" "REST BOOK" "TRADE IOC BUY 5 1" "FILLED BUY" "FILLED IOC" "CANCEL BOOK 1"]
         (run [ob/limit-order! "BUY" :buy 5 1]
              [ob/limit-order! "BOOK" :buy 4 1]
              [ob/limit-order! "IOC" :sell 5 1]
              [ob/cancel-order! "BOOK"]))))

(deftest duplicate-resting-id-is-rejected
  (let [b (ob/new-book)]
    (ob/limit-order! b "a" :buy 5 1)
    (is (= ["REJECT a"] (map ob/format-event (ob/limit-order! b "a" :sell 9 1))))
    (is (= {:bids [{:price 5 :qty 1 :orders 1}] :asks []} (ob/snapshot b)))))

(deftest sink-arity
  (let [b (ob/new-book) seen (atom [])]
    (is (nil? (ob/execute! b {:op :limit :id "a" :side :buy :price 1 :qty 1}
                           #(swap! seen conj %))))
    (is (= [{:event :rest :id "a"}] @seen))))

(deftest unknown-op
  (is (thrown? clojure.lang.ExceptionInfo (ob/execute! (ob/new-book) {:op :nope}))))
