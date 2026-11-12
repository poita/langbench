(ns orderbook.command-test
  (:require [clojure.test :refer [deftest is]]
            [orderbook.command :as command]))

(deftest parses-commands
  (is (= {:op :limit :id "a" :side :buy :price 100 :qty 5 :tif :gtc}
         (command/parse-line "LIMIT a BUY 100 5")))
  (is (= :ioc (:tif (command/parse-line "LIMIT a SELL 100 5 IOC"))))
  (is (= :fok (:tif (command/parse-line "LIMIT a SELL 100 5 FOK"))))
  (is (= {:op :market :id "m" :side :sell :qty 7} (command/parse-line "MARKET m SELL 7")))
  (is (= {:op :cancel :id "a"} (command/parse-line "CANCEL a")))
  (is (= {:op :replace :id "a" :price 3 :qty 4} (command/parse-line "REPLACE a 3 4")))
  (is (= {:op :book} (command/parse-line "BOOK"))))

(deftest ids-may-look-like-keywords
  (is (= {:op :cancel :id "BOOK"} (command/parse-line "CANCEL BOOK")))
  (is (= {:op :limit :id "IOC" :side :buy :price 1 :qty 1 :tif :ioc}
         (command/parse-line "LIMIT IOC BUY 1 1 IOC"))))

(deftest large-values-are-longs
  (is (= 1000000000 (:qty (command/parse-line "LIMIT a BUY 1 1000000000")))))

(deftest rejects-garbage
  (is (thrown? clojure.lang.ExceptionInfo (command/parse-line "NOPE a")))
  (is (thrown? clojure.lang.ExceptionInfo (command/parse-line "LIMIT a UP 1 1")))
  (is (thrown? clojure.lang.ExceptionInfo (command/parse-line "LIMIT a BUY 1 1 GTC"))))
